// swiftlint:disable cyclomatic_complexity function_body_length
import Fluent
import OrchardNestKit
import Queues
import Vapor

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
    context.application.http.client.configuration.timeout = HTTPClient.Configuration.Timeout(connect: .seconds(10), read: .seconds(10))

    let futureFeeds = maps.flatMap { (maps) -> EventLoopFuture<[(String, String, FeedChannel)?]> in
      context.logger.info("downloading feeds...")
      let (langMap, catMap) = maps
      return organizedSites.map { args in
        let (lang, cat, site) = args
        context.logger.info("downloading \(site.title)...")

        return context.application.client.get(URI(string: site.feed_url.absoluteString))
          .flatMapAlways { (result) -> EventLoopFuture<(String, String, FeedChannel)?> in

            let body: ByteBuffer?
            do {
              body = try result.get().body
            } catch {
              context.logger.info("\(site.title) URLERROR: \(error.localizedDescription)")
              body = nil
            }
            let feedChannelSet = body.flatMap { (buffer) -> (String, String, FeedChannel)? in
              let channel: FeedChannel
              do {
                channel = try FeedChannel(language: lang, category: cat, site: site, data: Data(buffer: buffer))
              } catch {
                context.logger.info("\(site.title) FEDERROR: \(error.localizedDescription)")
                return nil
              }
              guard channel.items.count > 0 || channel.itemCount == channel.items.count else {
                context.logger.info("\(site.title) ITMERROR")
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
            context.logger.info("saving yt video \"\(newVideo.youtubeId)\"")
            return newVideo.save(on: database)
          }
        }
    }

    // save podcastepisodes to entries

    let futPodEpisodes = futureEntries.mapEachCompact { (entry) -> PodcastEpisode? in

      guard let id = entry.0.id, let audioURL = entry.1.audio else {
        return nil
      }
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
          context.logger.info("saving podcast episode \"\(savingEpisode.audioURL)\"")
          return savingEpisode.save(on: database)
        }
    }

    return futYTVideos.and(futYTChannels).and(futPodEpisodes).transform(to: ())
  }
}
