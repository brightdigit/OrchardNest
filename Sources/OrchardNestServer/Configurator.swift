// swiftlint:disable cyclomatic_complexity function_body_length
import Fluent
import FluentPostgresDriver
import OrchardNestKit
import Queues
import QueuesFluentDriver
import Vapor

public protocol ConfiguratorProtocol {
  func configure(_ app: Application) throws
}

enum RefreshSource {
  case blogs(URL)
  case feeds(URL)
}

struct RefreshJob: Job {
  typealias Payload = URL

  func error(_ context: QueueContext, _ error: Error, _: URL) -> EventLoopFuture<Void> {
    context.logger.report(error: error)
    return context.eventLoop.future()
  }

  func dequeue(_ context: QueueContext, _: URL) -> EventLoopFuture<Void> {
    let database = context.application.db

    guard let url = URL(string: "https://raw.githubusercontent.com/daveverwer/iOSDevDirectory/master/blogs.json") else {
      return context.eventLoop.makeFailedFuture(NSError())
    }
    
    
      let decoder = JSONDecoder()
    

    let sites: [LanguageContent]
    context.logger.info("downloading blog list...")
    do {
      let data = try Data(contentsOf: url)
      sites = try decoder.decode([LanguageContent].self, from: data)
    } catch {
      return context.eventLoop.future(error: error)
    }

    var languages = [String: String]()
    var categories = [String: [String: String]]()
    var organizedSites = [OrganizedSite]()

    for lang in sites {
      languages[lang.language] = lang.title
      for category in lang.categories {
        var categoryMap = categories[category.slug] ?? [String: String]()
        categoryMap[lang.language] = category.title
        categories[category.slug] = categoryMap
        organizedSites.append(contentsOf: category.sites.map {
          (lang.language, category.slug, $0)
        })
      }
    }

    let futureLanguages = languages.map { pair in

      Language.find(pair.key, on: database).flatMap { (langOpt) -> EventLoopFuture<Language> in
        let language: Language
        if let actual = langOpt {
          actual.title = pair.value
          language = actual
        } else {
          language = Language(code: pair.key, title: pair.value)
        }
        return language.save(on: database).transform(to: language)
      }
    }.flatten(on: database.eventLoop)
    // save languages
    // save categories
    let futureCategories = categories.map { pair in

      Category.find(pair.key, on: database).flatMap { (langOpt) -> EventLoopFuture<Category> in
        let category: Category
        if let actual = langOpt {
          category = actual
        } else {
          category = Category(slug: pair.key)
        }
        return category.save(on: database).transform(to: category)
      }
    }.flatten(on: database.eventLoop)

    let maps = futureLanguages.and(futureCategories).map { (languages, categories) -> ([String: Language], [String: Category]) in
      context.logger.info("updated languages and categories")

      let langMap = Dictionary(uniqueKeysWithValues: languages.compactMap { lang in
        lang.id.map { ($0, lang) }
      })
      let catMap = Dictionary(uniqueKeysWithValues: categories.compactMap { cat in
        cat.id.map { ($0, cat) }
      })
      return (langMap, catMap)
    }

    // need map to lang, cats
    context.application.http.client.configuration.timeout = HTTPClient.Configuration.Timeout(connect: .seconds(5), read: .seconds(5))

    let futureFeeds = maps.flatMap { (maps) -> EventLoopFuture<[(String, String, FeedChannel)?]> in
      context.logger.info("downloading feeds...")
      let (langMap, catMap) = maps
      return organizedSites.map { args in
        let (lang, cat, site) = args
        context.logger.info("downloading \(site.title)...")

        return context.application.client.get(URI(string: site.feed_url.absoluteString))
          .flatMapAlways { (result) -> EventLoopFuture<(String, String, FeedChannel)?> in

            let feedChannelSet = (try? result.get())?.body.flatMap { (buffer) -> (String, String, FeedChannel)? in

              guard let channel = try? FeedChannel(language: lang, category: cat, site: site, data: Data(buffer: buffer)) else {
                return nil
              }
              guard let newLangId = langMap[lang]?.id else {
                return nil
              }
              guard let newCatId = catMap[cat]?.id else {
                return nil
              }
              context.logger.info("downloaded \(site.title)")
              return (newLangId, newCatId, channel)
            }
            return context.eventLoop.future(feedChannelSet)
          }
      }.flatten(on: context.eventLoop)
    }.mapEachCompact { $0 }

    let currentChannels = futureFeeds.map { (args) -> [String] in
      args.map {
        $0.2.siteUrl.absoluteString
      }
    }.flatMap { siteUrls in
      Channel.query(on: database).filter(\.$siteUrl ~~ siteUrls).all()
    }.map {
      Dictionary(uniqueKeysWithValues: ($0.map {
        ($0.siteUrl, $0)
      }))
    }

    let futureChannels = futureFeeds.and(currentChannels).map { (args) -> [(Channel, String?, [FeedItem])] in
      context.logger.info("beginning upserting channels...")
      let (feeds, currentChannels) = args
      return feeds.map { feedArgs in
        let (langId, catId, feedChannel) = feedArgs
        let channel: Channel
        if let oldChannel = currentChannels[feedChannel.siteUrl.absoluteString] {
          channel = oldChannel
        } else {
          channel = Channel()
        }
        channel.title = feedChannel.title
        channel.$language.id = langId
        // channel.language = language
        channel.$category.id = catId
        channel.subtitle = feedChannel.summary
        channel.author = feedChannel.author
        channel.siteUrl = feedChannel.siteUrl.absoluteString
        channel.feedUrl = feedChannel.feedUrl.absoluteString
        channel.twitterHandle = feedChannel.twitterHandle
        channel.imageURL = feedChannel.image?.absoluteString

        channel.publishedAt = feedChannel.updated

        return (channel, feedChannel.ytId, feedChannel.items)
      }
    }.flatMapEachCompact(on: database.eventLoop) { (args) -> EventLoopFuture<(Channel, String?, [FeedItem])?> in
      context.logger.info("saving \"\(args.0.title)\"")
      return args.0.save(on: database).transform(to: args).flatMapError { _ in database.eventLoop.future((Channel, String?, [FeedItem])?.none) }
    }

    // save youtube channels to channels
    let futYTChannels = futureChannels.mapEachCompact { (channel) -> YouTubeChannel? in
      guard let id = channel.0.id, let youtubeId = channel.1 else {
        return nil
      }
      context.logger.info("saving yt channel \"\(channel.0.title)\"")
      return YouTubeChannel(channelId: id, youtubeId: youtubeId)
    }.flatMapEach(on: database.eventLoop) { newChannel in

      YouTubeChannel.find(newChannel.id, on: database)
        .optionalMap { $0.youtubeId == newChannel.youtubeId ? $0 : nil }
        .flatMap { (channel) -> EventLoopFuture<Void> in
          guard let channelId = newChannel.id, channel == nil else {
            return database.eventLoop.makeSucceededFuture(())
          }

          return YouTubeChannel.query(on: database).group(.or) {
            $0.filter(\.$id == channelId).filter(\.$youtubeId == newChannel.youtubeId)
          }.all().flatMapEach(on: database.eventLoop) { channel in
            channel.delete(on: database)
          }.flatMap { _ in
            newChannel.save(on: database)
          }
        }
    }

    // save entries to channels
    let futureEntries = futureChannels.flatMapEachThrowing { (args) -> [(UUID, FeedItem)] in
      let (channel, _, feedItems) = args
      let channelId = try channel.requireID()
      return feedItems.map { (channelId, $0) }
    }
    .map { $0.flatMap { $0 } }
    .flatMapEach(on: database.eventLoop) { (channelId, feedItem) -> EventLoopFuture<(Entry, FeedItem)> in

      Entry.query(on: database).filter(\.$feedId == feedItem.id).first().flatMap { foundEntry in
        let newEntry: Entry
        if let entry = foundEntry {
          newEntry = entry
        } else {
          newEntry = Entry()
        }

        newEntry.$channel.id = channelId
        newEntry.content = feedItem.content
        newEntry.feedId = feedItem.id
        newEntry.imageURL = feedItem.image?.absoluteString
        newEntry.publishedAt = feedItem.published
        newEntry.summary = feedItem.summary
        newEntry.title = feedItem.title
        newEntry.url = feedItem.url.absoluteString
        context.logger.info("saving entry for \"\(feedItem.url)\"")
        return newEntry.save(on: database).transform(to: (newEntry, feedItem))
      }
    }

    // save videos to entries
    let futYTVideos = futureEntries.mapEachCompact { (entry) -> YoutubeVideo? in

      guard let id = entry.0.id, let youtubeId = entry.1.ytId else {
        return nil
      }
      context.logger.info("saving yt video \"\(entry.0.url)\"")
      return YoutubeVideo(entryId: id, youtubeId: youtubeId)
    }.flatMapEach(on: database.eventLoop) { newVideo in
      YoutubeVideo.find(newVideo.id, on: database)
        .optionalMap { $0.youtubeId == newVideo.youtubeId ? $0 : nil }
        .flatMap { (video) -> EventLoopFuture<Void> in
          guard let entryId = newVideo.id, video == nil else {
            return database.eventLoop.makeSucceededFuture(())
          }

          return YoutubeVideo.query(on: database).group(.or) {
            $0.filter(\.$id == entryId).filter(\.$youtubeId == newVideo.youtubeId)
          }.all().flatMapEach(on: database.eventLoop) { channel in
            channel.delete(on: database)
          }.flatMap { _ in
            newVideo.save(on: database)
          }
        }
    }

    // save podcastepisodes to entries

    let futPodEpisodes = futureEntries.mapEachCompact { (entry) -> PodcastEpisode? in

      guard let id = entry.0.id, let audioURL = entry.1.audio else {
        return nil
      }
      context.logger.info("saving podcast episode \"\(entry.0.url)\"")
      return PodcastEpisode(entryId: id, audioURL: audioURL.absoluteString)
    }.flatMapEach(on: database.eventLoop) { newEpisode in
      PodcastEpisode.find(newEpisode.id, on: database)
        .flatMap { (episode) -> EventLoopFuture<Void> in
          let savingEpisode: PodcastEpisode
          if let oldEpisode = episode {
            oldEpisode.audioURL = newEpisode.audioURL
            savingEpisode = oldEpisode
          } else {
            savingEpisode = newEpisode
          }
          return savingEpisode.save(on: database)
        }
    }

    return futYTVideos.and(futYTChannels).and(futPodEpisodes).transform(to: ())
  }
}

extension RefreshSource: LosslessStringConvertible {
  init?(_ description: String) {
    let components = description.components(separatedBy: ";")
    guard components.count == 2 else {
      return nil
    }

    guard let first = components.first else {
      return nil
    }

    guard let last = components.last.flatMap(URL.init(string:)) else {
      return nil
    }

    switch first {
    case "blogs":
      self = .blogs(last)
    case "feeds":
      self = .feeds(last)
    default:
      return nil
    }
  }

  var description: String {
    let first: String
    let last: URL
    switch self {
    case let .blogs(url): first = "blogs"; last = url
    case let .feeds(url): first = "feeds"; last = url
    }
    return [first, last.absoluteString].joined(separator: ";")
  }
}

typealias OrganizedSite = (String, String, Site)
struct RefreshSignature: CommandSignature {
  init() {}

  @Argument(name: "Blogs Source URL")
  var blogSourceURL: String
}

struct RefreshCommand: Command {
  typealias Signature = RefreshSignature

  var help: String

  func run(using _: CommandContext, signature _: RefreshSignature) throws {}
}

//
public final class Configurator: ConfiguratorProtocol {
  public static let shared: ConfiguratorProtocol = Configurator()

  //
  ///// Called before your application initializes.
  public func configure(_ app: Application) throws {
    // Register providers first
    // try services.register(FluentPostgreSQLProvider())
    // try services.register(AuthenticationProvider())

    // services.register(DirectoryIndexMiddleware.self)

    // Register middleware
    // var middlewares = MiddlewareConfig() // Create _empty_ middleware config
    // middlewares.use(SessionsMiddleware.self) // Enables sessions.
    //let rootPath = Environment.get("ROOT_PATH") ?? app.directory.publicDirectory

//    app.webSockets = WebSocketRepository()
//
//    app.middleware.use(DirectoryIndexMiddleware(publicDirectory: rootPath))

    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    // middlewares.use(ErrorMiddleware.self) // Catches errors and converts to HTTP response
    // services.register(middlewares)

    // Configure a SQLite database
    let postgreSQLConfig: PostgresConfiguration

    if let url = Environment.get("DATABASE_URL") {
      postgreSQLConfig = PostgresConfiguration(url: url)!
    } else {
      postgreSQLConfig = PostgresConfiguration(hostname: "localhost", username: "orchardnest")
    }

    app.databases.use(.postgres(configuration: postgreSQLConfig), as: .psql)

    app.migrations.add([
      CategoryMigration(),
      LanguageMigration(),
      CategoryTitleMigration(),
      ChannelMigration(),
      EntryMigration(),
      PodcastEpisodeMigration(),
      YouTubeChannelMigration(),
      YouTubeVideoMigration(),
      JobModelMigrate(schema: "queue_jobs")
    ])

    app.queues.configuration.refreshInterval = .seconds(25)
    app.queues.use(.fluent())
//    app.databases.middleware.use(UserEmailerMiddleware(app: app))
//
//    app.migrations.add(CreateDevice())
//    app.migrations.add(CreateAppleUser())
//    app.migrations.add(CreateDeviceWorkout())
//    app.migrations.add(ActivateWorkout())
    // let wss = NIOWebSocketServer.default()

//    app.webSocket("api", "v1", "workouts", ":id", "listen") { req, websocket in
//      guard let idData = try? Base32CrockfordEncoding.encoding.decode(base32Encoded: req.parameters.get("id")!) else {
//        return
//      }
//      let workoutID = UUID(data: idData)
//
//      _ = Workout.find(workoutID, on: req.db).unwrap(or: Abort(HTTPResponseStatus.notFound)).flatMapThrowing { workout in
//        let workoutId = try workout.requireID()
//        app.webSockets.save(websocket, withID: workoutId)
//      }
//    }

    app.queues.add(RefreshJob())
    // try app.queues.startInProcessJobs(on: .default)
    // app.commands.use(RefreshCommand(help: "Imports data into the database"), as: "refresh")

    try app.autoMigrate().wait()
    //   services.register(wss, as: WebSocketServer.self)
    app.get { req in
      req.queue.dispatch(
        RefreshJob.self,
        URL(string: "https://raw.githubusercontent.com/daveverwer/iOSDevDirectory/master/blogs.json")!
      ).map { "Hello" }
    }
  }
}
