import Fluent
import FluentPostgresDriver
import OrchardNestKit
import Vapor

public protocol ConfiguratorProtocol {
  func configure(_ app: Application) throws
}

enum RefreshSource {
  case blogs(URL)
  case feeds(URL)
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

  // swiftlint:disable:next function_body_length cyclomatic_complexity
  func run(using context: CommandContext, signature: RefreshSignature) throws {
    let database = context.application.db

    guard let url = URL(string: signature.blogSourceURL) else {
      return
    }

    // let blogs = URL(string: "https://raw.githubusercontent.com/daveverwer/iOSDevDirectory/master/blogs.json")!

    let reader = BlogReader()
    let sites = try reader.sites(fromURL: url)

    var languages = [String: String]()
    var categories = [String: String]()
    var organizedSites = [OrganizedSite]()

    for lang in sites {
      languages[lang.language] = lang.title
      for category in lang.categories {
        categories[category.slug] = category.title
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
          actual.title = pair.value
          category = actual
        } else {
          category = Category(slug: pair.key, title: pair.value)
        }
        return category.save(on: database).transform(to: category)
      }
    }.flatten(on: database.eventLoop)

    // need map to lang, cats

    // save channels
    let futureChannels = futureLanguages.and(futureCategories)
      .flatMap { (languages, categories) -> EventLoopFuture<[(Channel, String?, [FeedItem])]> in

        let langMap = Dictionary(uniqueKeysWithValues: languages.map {
          ($0.id, $0)
        })
        let catMap = Dictionary(uniqueKeysWithValues: categories.map {
          ($0.id, $0)
        })
        return organizedSites.map { (args) -> EventLoopFuture<(Channel, String?, [FeedItem])?> in
          let (lang, cat, site) = args
          return Channel.query(on: database).filter("site_url", .equal, site.site_url).first()
            .flatMap { (foundChannel) -> EventLoopFuture<(Channel, String?, [FeedItem])?> in
              let channel: Channel
              if let oldChannel = foundChannel {
                channel = oldChannel
              } else {
                channel = Channel()
              }

              if let language = langMap[lang],
                let category = catMap[cat],
                let feedChannel = try? FeedChannel(language: lang, category: cat, site: site) {
                channel.title = feedChannel.title
                channel.language = language
                channel.category = category
                channel.subtitle = feedChannel.summary
                channel.author = feedChannel.author
                channel.siteUrl = feedChannel.siteUrl
                channel.feedUrl = feedChannel.feedUrl
                channel.twitterHandle = feedChannel.twitterHandle
                channel.image = feedChannel.image

                channel.publishedAt = feedChannel.updated
                return channel.save(on: database).transform(to: (channel, feedChannel.ytId, feedChannel.items))
              } else {
                return database.eventLoop.makeSucceededFuture(nil)
              }
            }
        }.flatten(on: database.eventLoop).mapEachCompact { $0 }
      }

    // save youtube channels to channels
    let futYTChannels = futureChannels.mapEachCompact { (channel) -> YouTubeChannel? in
      guard let id = channel.0.id, let youtubeId = channel.1 else {
        return nil
      }
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
    let futureEntries = futureChannels.flatMapEach(on: database.eventLoop) { (args) -> EventLoopFuture<[(Entry, FeedItem)]> in
      let (channel, _, feedItems) = args
      return feedItems.map { (feedItem) -> EventLoopFuture<(Entry, FeedItem)> in
        Entry.query(on: database).filter(\.$feedId == feedItem.id).first().flatMap { foundEntry in
          let newEntry: Entry
          if let entry = foundEntry {
            newEntry = entry
          } else {
            newEntry = Entry()
          }
          newEntry.channel = channel
          newEntry.content = feedItem.content
          newEntry.feedId = feedItem.id
          newEntry.image = feedItem.image
          newEntry.publishedAt = feedItem.published
          newEntry.summary = feedItem.summary
          newEntry.title = feedItem.title
          newEntry.url = feedItem.url
          return newEntry.save(on: database).transform(to: (newEntry, feedItem))
        }
      }.flatten(on: database.eventLoop)
    }.map {
      $0.flatMap { $0 }
    }

    // save videos to entries
    let futYTVideos = futureEntries.mapEachCompact { (entry) -> YoutubeVideo? in

      guard let id = entry.0.id, let youtubeId = entry.1.ytId else {
        return nil
      }
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
      return PodcastEpisode(entryId: id, audioURL: audioURL)
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

    try futYTVideos.and(futYTChannels).and(futPodEpisodes).transform(to: ()).wait()
  }
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
    let rootPath = Environment.get("ROOT_PATH") ?? app.directory.publicDirectory

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
      ChannelMigration(),
      EntryMigration(),
      PodcastEpisodeMigration(),
      YouTubeChannelMigration(),
      YouTubeVideoMigration()
    ])

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
    try app.autoMigrate().wait()
    //   services.register(wss, as: WebSocketServer.self)
    app.get { _ in
      "Hello"
    }
  }
}
