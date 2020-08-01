import Fluent
import OrchardNestKit
import Queues
import Vapor

struct FeedItemEntry {
  let entry: Entry
  let feedItem: FeedItem

  static func from(upsertOn database: Database, from config: FeedItemConfiguration) -> EventLoopFuture<FeedItemEntry> {
    Entry.query(on: database).filter(\.$feedId == config.feedItem.id).first().flatMap { foundEntry in
      let newEntry: Entry
      if let entry = foundEntry {
        newEntry = entry
      } else {
        newEntry = Entry()
      }

      newEntry.$channel.id = config.channelId
      newEntry.content = config.feedItem.content
      newEntry.feedId = config.feedItem.id
      newEntry.imageURL = config.feedItem.image?.absoluteString
      newEntry.publishedAt = config.feedItem.published
      newEntry.summary = config.feedItem.summary
      newEntry.title = config.feedItem.title
      newEntry.url = config.feedItem.url.absoluteString
      // context.logger.info("saving entry for \"\(config.feedItem.url)\"")
      return newEntry.save(on: database).transform(to: Self(entry: newEntry, feedItem: config.feedItem))
    }
  }
}

extension FeedItemEntry {
  var podcastEpisode: PodcastEpisode? {
    guard let id = entry.id, let audioURL = feedItem.audio else {
      return nil
    }
    return PodcastEpisode(entryId: id, audioURL: audioURL.absoluteString)
  }

  var youtubeVideo: YoutubeVideo? {
    guard let id = entry.id, let youtubeId = feedItem.ytId else {
      return nil
    }
    return YoutubeVideo(entryId: id, youtubeId: youtubeId)
  }
}

struct FeedItemConfiguration {
  let channelId: UUID
  let feedItem: FeedItem
}

// Channel, String?, [FeedItem]
struct FeedConfiguration {
  let categorySlug: String
  let languageCode: String
  let channel: FeedChannel
}

struct ChannelFeedItemsConfiguration {
  let channel: Channel
  let youtubeId: String?
  let items: [FeedItem]

  init(channels: [String: Channel], feedArgs: FeedConfiguration) {
    let channel: Channel
    if let oldChannel = channels[feedArgs.channel.siteUrl.absoluteString] {
      channel = oldChannel
    } else {
      channel = Channel()
    }
    channel.title = feedArgs.channel.title
    channel.$language.id = feedArgs.languageCode
    // channel.language = language
    channel.$category.id = feedArgs.categorySlug
    channel.subtitle = feedArgs.channel.summary
    channel.author = feedArgs.channel.author
    channel.siteUrl = feedArgs.channel.siteUrl.absoluteString
    channel.feedUrl = feedArgs.channel.feedUrl.absoluteString
    channel.twitterHandle = feedArgs.channel.twitterHandle
    channel.imageURL = feedArgs.channel.image?.absoluteString

    channel.publishedAt = feedArgs.channel.updated

    // return (channel, feedArgs.channel.ytId, feedArgs.channel.items)
    self.channel = channel
    items = feedArgs.channel.items
    youtubeId = feedArgs.channel.ytId
  }
}

extension ChannelFeedItemsConfiguration {
  func feedItems() throws -> [FeedItemConfiguration] {
    let channelId = try channel.requireID()
    return items.map { FeedItemConfiguration(channelId: channelId, feedItem: $0) }
  }
}

extension FeedConfiguration {
  static func from(
    categorySlug: String,
    languageCode: String,
    channel: FeedChannel,
    langMap: [String: Language],
    catMap: [String: Category]
  ) -> FeedResult {
    guard let newLangId = langMap[languageCode]?.id else {
      return .failure(.invalidParent(channel.feedUrl, languageCode))
    }
    guard let newCatId = catMap[categorySlug]?.id else {
      return .failure(.invalidParent(channel.feedUrl, categorySlug))
    }
    return .success(FeedConfiguration(categorySlug: newCatId, languageCode: newLangId, channel: channel))
  }
}

enum FeedError: Error {
  case download(URL, Error)
  case empty(URL)
  case parser(URL, Error)
  case items(URL)
  case invalidParent(URL, String)
}

typealias FeedResult = Result<FeedConfiguration, FeedError>

struct SiteCatalogMap {
  let languages: [String: String]
  let categories: [String: [String: String]]
  let organizedSites: [OrganizedSite]

  init(sites: [LanguageContent]) {
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
          OrganizedSite(languageCode: lang.language, categorySlug: category.slug, site: $0)
        })
      }
    }

    self.categories = categories
    self.languages = languages
    self.organizedSites = organizedSites
  }
}

extension Language {
  static func from(_ pair: (String, String), on database: Database) -> EventLoopFuture<Language> {
    Language.find(pair.0, on: database).flatMap { (langOpt) -> EventLoopFuture<Language> in
      let language: Language
      if let actual = langOpt {
        actual.title = pair.1
        language = actual
      } else {
        language = Language(code: pair.0, title: pair.1)
      }
      return language.save(on: database).transform(to: language)
    }
  }
}

extension Category {
  static func from(_ slug: String, on database: Database) -> EventLoopFuture<Category> {
    Category.find(slug, on: database).flatMap { (langOpt) -> EventLoopFuture<Category> in
      let category: Category
      if let actual = langOpt {
        category = actual
      } else {
        category = Category(slug: slug)
      }
      return category.save(on: database).transform(to: category)
    }
  }
}

extension Model {
  static func dictionary<IDType>(from elements: [Self]) -> [IDType: Self] where IDType == Self.IDValue {
    return Dictionary(uniqueKeysWithValues:
      elements.compactMap { model in
        model.id.map { ($0, model) }
      }
    )
  }
}

extension FeedChannel {
  static func parseSite(_ site: OrganizedSite, using client: Client, on eventLoop: EventLoop) -> EventLoopFuture<Result<FeedChannel, FeedError>> {
    let uri = URI(string: site.site.feed_url.absoluteString)
    let headers = HTTPHeaders([("Host", uri.host!), ("User-Agent", "OrchardNest-Robot"), ("Accept", "*/*")])

    let request = ClientRequest(method: .GET, url: uri, headers: headers, body: nil)

    return client.send(request)
      .flatMapAlways { (result) -> EventLoopFuture<Result<FeedChannel, FeedError>> in

        let responseBody: ByteBuffer?
        do {
          responseBody = try result.get().body
        } catch {
          // context.logger.info("\(site.title) URLERROR: \(error.localizedDescription) \(site.feed_url)")
          return eventLoop.future(.failure(.download(site.site.feed_url, error)))
        }
        guard let buffer = responseBody else {
          return eventLoop.future(.failure(.empty(site.site.feed_url)))
        }
        // let feedChannelSet = body.map { (buffer) -> FeedResult in
        let channel: FeedChannel
        do {
          channel = try FeedChannel(language: site.languageCode, category: site.categorySlug, site: site.site, data: Data(buffer: buffer))
        } catch {
          // context.logger.info("\(site.title) FEDERROR: \(error.localizedDescription) \(site.feed_url)")
          return eventLoop.future(.failure(.parser(site.site.feed_url, error)))
        }
        guard channel.items.count > 0 || channel.itemCount == channel.items.count else {
          // context.logger.info("\(site.title) ITMERROR \(site.feed_url)")
          return eventLoop.future(.failure(.items(site.site.feed_url)))
        }
//        guard let newLangId = langMap[lang]?.id else {
//          return context.eventLoop.future(.failure(.invalidParent(site.feed_url, lang)))
//        }
//        guard let newCatId = catMap[cat]?.id else {
//          return context.eventLoop.future(.failure(.invalidParent(site.feed_url, cat)))
//        }
        // context.logger.info("downloaded \(site.title)")
        return eventLoop.future(.success(channel))
        // }
        // return context.eventLoop.future(feedChannelSet)
      }
  }
}

extension YoutubeVideo {
  static func upsert(_ newVideo: YoutubeVideo, on database: Database) -> EventLoopFuture<Void> {
    return YoutubeVideo.find(newVideo.id, on: database)
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
          // context.logger.info("saving yt video \"\(newVideo.youtubeId)\"")
          newVideo.save(on: database)
        }
      }
  }
}

extension PodcastEpisode {
  static func upsert(_ newEpisode: PodcastEpisode, on database: Database) -> EventLoopFuture<Void> {
    return PodcastEpisode.find(newEpisode.id, on: database)
      .flatMap { (episode) -> EventLoopFuture<Void> in
        let savingEpisode: PodcastEpisode
        if let oldEpisode = episode {
          oldEpisode.audioURL = newEpisode.audioURL
          savingEpisode = oldEpisode
        } else {
          savingEpisode = newEpisode
        }
        // context.logger.info("saving podcast episode \"\(savingEpisode.audioURL)\"")
        return savingEpisode.save(on: database)
      }
  }
}

struct RefreshJob: Job {
  static let url = URL(string: "https://raw.githubusercontent.com/daveverwer/iOSDevDirectory/master/blogs.json")!
  typealias Payload = RefreshConfiguration

  func error(_ context: QueueContext, _ error: Error, _: RefreshConfiguration) -> EventLoopFuture<Void> {
    context.logger.report(error: error)
    return context.eventLoop.future()
  }

  func dequeue(_ context: QueueContext, _: RefreshConfiguration) -> EventLoopFuture<Void> {
    let database = context.application.db

    let decoder = JSONDecoder()

    let sites: [LanguageContent]
    context.logger.info("downloading blog list...")
    do {
      let data = try Data(contentsOf: Self.url)
      sites = try decoder.decode([LanguageContent].self, from: data)
    } catch {
      return context.eventLoop.future(error: error)
    }

//    var languages = [String: String]()
//    var categories = [String: [String: String]]()
//    var organizedSites = [OrganizedSite]()
//
//    for lang in sites {
//      languages[lang.language] = lang.title
//      for category in lang.categories {
//        var categoryMap = categories[category.slug] ?? [String: String]()
//        categoryMap[lang.language] = category.title
//        categories[category.slug] = categoryMap
//        organizedSites.append(contentsOf: category.sites.map {
//          (lang.language, category.slug, $0)
//        })
//      }
//    }

    let siteCatalogMap = SiteCatalogMap(sites: sites)

    let languages = siteCatalogMap.languages
    let categories = siteCatalogMap.categories
    let organizedSites = siteCatalogMap.organizedSites

    let futureLanguages = languages.map { Language.from($0, on: database) }.flatten(on: database.eventLoop)
    let futureCategories = categories.map { Category.from($0.key, on: database) }.flatten(on: database.eventLoop)

//    let futureLanguages = languages.map { pair in
//
//      Language.find(pair.key, on: database).flatMap { (langOpt) -> EventLoopFuture<Language> in
//        let language: Language
//        if let actual = langOpt {
//          actual.title = pair.value
//          language = actual
//        } else {
//          language = Language(code: pair.key, title: pair.value)
//        }
//        return language.save(on: database).transform(to: language)
//      }
//    }.flatten(on: database.eventLoop)

    // save languages
    // save categories
//    let futureCategories = categories.map { pair in
//
//      Category.find(pair.key, on: database).flatMap { (langOpt) -> EventLoopFuture<Category> in
//        let category: Category
//        if let actual = langOpt {
//          category = actual
//        } else {
//          category = Category(slug: pair.key)
//        }
//        return category.save(on: database).transform(to: category)
//      }
//    }.flatten(on: database.eventLoop)

    let langMap = futureLanguages.map(Language.dictionary(from:))
    let catMap = futureCategories.map(Category.dictionary(from:))
//    let mapz = futureLanguages.and(futureCategories).map { (languages, categories) -> ([String: Language], [String: Category]) in
//      context.logger.info("updated languages and categories")
//
//      let langMap = Dictionary(uniqueKeysWithValues: languages.compactMap { lang in
//        lang.id.map { ($0, lang) }
//      })
//      let catMap = Dictionary(uniqueKeysWithValues: categories.compactMap { cat in
//        cat.id.map { ($0, cat) }
//      })
//      return (langMap, catMap)
//    }

    // need map to lang, cats

    let futureFeedResults: EventLoopFuture<[FeedResult]>
    futureFeedResults = langMap.and(catMap).flatMap { (maps) -> EventLoopFuture<[FeedResult]> in
      context.logger.info("downloading feeds...")
      let (langMap, catMap) = maps
      return organizedSites.map { orgSite in
        FeedChannel.parseSite(orgSite, using: context.application.client, on: context.eventLoop)
          .map { result in
            result.flatMap { FeedConfiguration.from(
              categorySlug: orgSite.categorySlug,
              languageCode: orgSite.languageCode,
              channel: $0,
              langMap: langMap,
              catMap: catMap
            )
//              (channel) -> FeedResult in
//              guard let newLangId = langMap[orgSite.languageCode]?.id else {
//                return .failure(.invalidParent(orgSite.site.feed_url, orgSite.languageCode))
//              }
//              guard let newCatId = catMap[orgSite.categorySlug]?.id else {
//                return .failure(.invalidParent(orgSite.site.feed_url, orgSite.categorySlug))
//              }
//              context.logger.info("downloaded \(orgSite.site.title)")
//              return .success(FeedConfiguration(categorySlug: newCatId, languageCode: newLangId, channel: channel))
            }
          }
      }.flatten(on: context.eventLoop)
    }

    let futureFeeds = futureFeedResults.mapEachCompact { try? $0.get() }
    let currentChannels = futureFeeds.map { (args) -> [String] in
      args.map {
        $0.channel.siteUrl.absoluteString
      }
    }.flatMap { siteUrls in
      Channel.query(on: database).filter(\.$siteUrl ~~ siteUrls).all()
    }.map {
      Dictionary(uniqueKeysWithValues: ($0.map {
        ($0.siteUrl, $0)
      }))
    }

    let futureChannels = futureFeeds.and(currentChannels).map { (args) -> [ChannelFeedItemsConfiguration] in
      context.logger.info("beginning upserting channels...")
      let (feeds, currentChannels) = args

      return feeds.map { feedArgs in
        ChannelFeedItemsConfiguration(channels: currentChannels, feedArgs: feedArgs)
//        let channel: Channel
//        if let oldChannel = currentChannels[feedArgs.channel.siteUrl.absoluteString] {
//          channel = oldChannel
//        } else {
//          channel = Channel()
//        }
//        channel.title = feedArgs.channel.title
//        channel.$language.id = feedArgs.languageCode
//        // channel.language = language
//        channel.$category.id = feedArgs.categorySlug
//        channel.subtitle = feedArgs.channel.summary
//        channel.author = feedArgs.channel.author
//        channel.siteUrl = feedArgs.channel.siteUrl.absoluteString
//        channel.feedUrl = feedArgs.channel.feedUrl.absoluteString
//        channel.twitterHandle = feedArgs.channel.twitterHandle
//        channel.imageURL = feedArgs.channel.image?.absoluteString
//
//        channel.publishedAt = feedArgs.channel.updated
//
//        return (channel, feedArgs.channel.ytId, feedArgs.channel.items)
      }
    }.flatMapEachCompact(on: database.eventLoop) { (args) -> EventLoopFuture<ChannelFeedItemsConfiguration?> in

      context.logger.info("saving \"\(args.channel.title)\"")
      return args.channel.save(on: database).transform(to: args).flatMapError { _ in database.eventLoop.future(ChannelFeedItemsConfiguration?.none) }
    }

    // save youtube channels to channels
    let futYTChannels = futureChannels.mapEachCompact { (channel) -> YouTubeChannel? in
      guard let id = channel.channel.id, let youtubeId = channel.youtubeId else {
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
            context.logger.info("saving yt channel \"\(newChannel.youtubeId)\"")
            return newChannel.save(on: database)
          }
        }
    }

    // save entries to channels
    let futureEntries = futureChannels
      .flatMapEachThrowing { try $0.feedItems() }
      .map { $0.flatMap { $0 } }
      .flatMapEach(on: database.eventLoop) { (config) -> EventLoopFuture<FeedItemEntry> in

        FeedItemEntry.from(upsertOn: database, from: config)
//        Entry.query(on: database).filter(\.$feedId == config.feedItem.id).first().flatMap { foundEntry in
//          let newEntry: Entry
//          if let entry = foundEntry {
//            newEntry = entry
//          } else {
//            newEntry = Entry()
//          }
//
//          newEntry.$channel.id = config.channelId
//          newEntry.content = config.feedItem.content
//          newEntry.feedId = config.feedItem.id
//          newEntry.imageURL = config.feedItem.image?.absoluteString
//          newEntry.publishedAt = config.feedItem.published
//          newEntry.summary = config.feedItem.summary
//          newEntry.title = config.feedItem.title
//          newEntry.url = config.feedItem.url.absoluteString
//          context.logger.info("saving entry for \"\(config.feedItem.url)\"")
//          return newEntry.save(on: database).transform(to: (newEntry, config.feedItem))
//        }
      }

    // save videos to entries
    let futYTVideos = futureEntries.mapEachCompact { (entry) -> YoutubeVideo? in

      entry.youtubeVideo
    }.flatMapEach(on: database.eventLoop) { newVideo in
      YoutubeVideo.upsert(newVideo, on: database)
//      YoutubeVideo.find(newVideo.id, on: database)
//        .optionalMap { $0.youtubeId == newVideo.youtubeId ? $0 : nil }
//        .flatMap { (video) -> EventLoopFuture<Void> in
//          guard let entryId = newVideo.id, video == nil else {
//            return database.eventLoop.makeSucceededFuture(())
//          }
//
//          return YoutubeVideo.query(on: database).group(.or) {
//            $0.filter(\.$id == entryId).filter(\.$youtubeId == newVideo.youtubeId)
//          }.all().flatMapEach(on: database.eventLoop) { channel in
//            channel.delete(on: database)
//          }.flatMap { _ in
//            context.logger.info("saving yt video \"\(newVideo.youtubeId)\"")
//            return newVideo.save(on: database)
//          }
//        }
    }

    // save podcastepisodes to entries

    let futPodEpisodes = futureEntries.mapEachCompact { (entry) -> PodcastEpisode? in

      entry.podcastEpisode
    }.flatMapEach(on: database.eventLoop) { newEpisode in
      PodcastEpisode.upsert(newEpisode, on: database)
//      PodcastEpisode.find(newEpisode.id, on: database)
//        .flatMap { (episode) -> EventLoopFuture<Void> in
//          let savingEpisode: PodcastEpisode
//          if let oldEpisode = episode {
//            oldEpisode.audioURL = newEpisode.audioURL
//            savingEpisode = oldEpisode
//          } else {
//            savingEpisode = newEpisode
//          }
//          context.logger.info("saving podcast episode \"\(savingEpisode.audioURL)\"")
//          return savingEpisode.save(on: database)
//        }
    }

    return futYTVideos.and(futYTChannels).and(futPodEpisodes).transform(to: ())
  }
}
