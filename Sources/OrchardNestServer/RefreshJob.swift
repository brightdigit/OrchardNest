import Fluent
import NIO
import OrchardNestKit
import Queues
import Vapor
extension Collection {
  func chunked(by distance: Int) -> [[Element]] {
    var result: [[Element]] = []
    var batch: [Element] = []

    for element in self {
      batch.append(element)

      if batch.count == distance {
        result.append(batch)
        batch = []
      }
    }

    if !batch.isEmpty {
      result.append(batch)
    }

    return result
  }
}

struct ApplePodcastResult: Codable {
  let collectionId: Int
}

struct ApplePodcastResponse: Codable {
  let results: [ApplePodcastResult]
}

struct RefreshScheduledJob: ScheduledJob {
  func run(context: QueueContext) -> EventLoopFuture<Void> {
    context.queue.dispatch(
      RefreshJob.self,
      RefreshConfiguration()
    )
  }
}

struct RefreshJob: Job {
 
  typealias Payload = RefreshConfiguration

  func error(_ context: QueueContext, _ error: Error, _: RefreshConfiguration) -> EventLoopFuture<Void> {
    context.logger.report(error: error)
    return context.eventLoop.future()
  }
  

  
  func dequeue(_ context: QueueContext, _: RefreshConfiguration) -> EventLoopFuture<Void> {
    let database = context.application.db
    let client = context.application.client

    let decoder = JSONDecoder()

    let process = RefreshProcess()
    
    return process.begin(using: RefreshParameters(logger: context.logger, database: context.application.db, client: context.application.client), on: context.eventLoop)
  }
}

class RefreshParameters {
  internal init(logger: Logger, database: Database, client: Client, decoder: JSONDecoder = JSONDecoder()) {
    self.logger = logger
    self.database = database
    self.client = client
    self.decoder = decoder
  }
  
  let logger : Logger
  let database : Database
  let client : Client
  let decoder : JSONDecoder
}

struct RefreshProcess {
  static let youtubeAPIKey = Environment.get("YOUTUBE_API_KEY")!

  static let url = URL(string: "https://raw.githubusercontent.com/daveverwer/iOSDevDirectory/master/blogs.json")!

  static let basePodcastQueryURLComponents = URLComponents(string: """
  https://itunes.apple.com/search?media=podcast&attribute=titleTerm&limit=1&entity=podcast
  """)!

  static let youtubeQueryURLComponents = URLComponents(string: """
  https://www.googleapis.com/youtube/v3/videos?part=contentDetails&fields=items%2Fid%2Citems%2FcontentDetails%2Fduration&key=\(Self.youtubeAPIKey)
  """)!

  static func queryURL(forYouTubeWithIds ids: [String]) -> URI {
    var components = Self.youtubeQueryURLComponents
    guard var queryItems = components.queryItems else {
      preconditionFailure()
    }
    queryItems.append(URLQueryItem(name: "id", value: ids.joined(separator: ",")))
    components.queryItems = queryItems
    return URI(
      scheme: components.scheme,
      host: components.host,
      port: components.port,
      path: components.path,
      query: components.query,
      fragment: components.fragment
    )
  }

  static func queryURL(forPodcastWithTitle title: String) -> URI {
    var components = Self.basePodcastQueryURLComponents
    guard var queryItems = components.queryItems else {
      preconditionFailure()
    }
    queryItems.append(URLQueryItem(name: "term", value: title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)))
    components.queryItems = queryItems
    return URI(
      scheme: components.scheme,
      host: components.host,
      port: components.port,
      path: components.path,
      query: components.query,
      fragment: components.fragment
    )
  }

  struct FeedResultResponse {
    internal init(maps: ([Language], [Category]), organizedSites: [OrganizedSite]) {
      self.languages = maps.0
      self.categories = maps.1
      self.organizedSites = organizedSites
    }
    
    let languages : [Language]
    let categories : [Category]
    let organizedSites : [OrganizedSite]
  }
  
  func download (basedOn response: FeedResultResponse, using client: Client, on eventLoop: EventLoop, with logger: Logger) -> EventLoopFuture<[FeedResult]> {
    //let futureFeedResults: EventLoopFuture<[FeedResult]>
    let langMap = Language.dictionary(from: response.languages)
    let catMap = Category.dictionary(from: response.categories)
//    futureFeedResults = langMap.and(catMap).flatMap { maps -> EventLoopFuture<[FeedResult]> in
     logger.info("downloading feeds...")

      var results = [EventLoopFuture<FeedResult>]()
      let promise = eventLoop.makePromise(of: Void.self)
      _ = eventLoop.scheduleRepeatedAsyncTask(
        initialDelay: .seconds(1),
        delay: .nanoseconds(20_000_000)
      ) { (task: RepeatedTask) -> EventLoopFuture<Void> in
        guard results.count < response.organizedSites.count else {
          task.cancel(promise: promise)

          logger.info("finished downloading feeds...")
          return eventLoop.makeSucceededFuture(())
        }
        let args = response.organizedSites[results.count]
        logger.info("downloading \"\(args.site.feed_url)\"")
        let result = FeedChannel.parseSite(args, using: client, on: eventLoop).map { result -> FeedResult in
          result.flatMap { FeedConfiguration.from(
            categorySlug: args.categorySlug,
            languageCode: args.languageCode,
            channel: $0,
            langMap: langMap,
            catMap: catMap
          )
          }.flatMap { configuration in
            let temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(),
                                                isDirectory: true)
            let id = UUID()
            let fileURL = temporaryDirectoryURL.appendingPathComponent(id.uuidString)
            let encoder = JSONEncoder()
            do {
              let data = try encoder.encode(configuration)
              try data.write(to: fileURL, options: .atomic)
            } catch {
              return .failure(.internalError(error))
            }
            return .success( fileURL)
          }
        }
        results.append(result)
        return result.transform(to: ())
      }
      let finalResults = promise.futureResult.flatMap {
        results.flatten(on: eventLoop)
      }

      return finalResults
    
  }
  
  // swiftlint:disable:next function_body_length
  func begin(using parameters: RefreshParameters, on eventLoop: EventLoop) -> EventLoopFuture<Void> {
    parameters.logger.info("downloading blog list...")
    
    let blogsDownload = parameters.client.get(URI(string: Self.url.absoluteString)).flatMapThrowing { response -> [LanguageContent] in
      try response.content.decode([LanguageContent].self, using: parameters.decoder)
    }.map(SiteCatalogMap.init)
    
    let ignoringFeedURLs = ChannelStatus.query(on: parameters.database)
      .filter(\.$status == ChannelStatusType.ignore)
      .field(\.$id)
      .all()
      .map { $0.compactMap { $0.id.flatMap(URL.init(string:)) }}
    
    return blogsDownload.and(ignoringFeedURLs).flatMap { siteCatalogMap, ignoringFeedURLs -> EventLoopFuture<Void> in
      let languages = siteCatalogMap.languages
      let categories = siteCatalogMap.categories
      let organizedSites = siteCatalogMap.organizedSites.filter {
        !ignoringFeedURLs.contains($0.site.feed_url)
      }
      
      let channelCleanup = Channel.query(on: parameters.database).filter(\.$feedUrl ~~ ignoringFeedURLs.map { $0.absoluteString }).delete()
      
      let futureLanguages = languages.map { Language.from($0, on: parameters.database) }.flatten(on: eventLoop)
      let futureCategories = categories.map { Category.from($0.key, on: parameters.database) }.flatten(on: eventLoop)
      
      
      // need map to lang, cats
      
      let feedResultResponse = futureLanguages.and(futureCategories).and(value: organizedSites).map(FeedResultResponse.init)
      let futureFeedResults = feedResultResponse.flatMap{
        self.download(basedOn: $0, using: parameters.client, on: eventLoop, with: parameters.logger)
      }
      let groupedResults = futureFeedResults.map { results -> ([URL], [FeedError]) in
        var errors = [FeedError]()
        var configurations = [URL]()
        results.forEach {
          switch $0 {
          case let .success(config): configurations.append(config)
          case let .failure(error): errors.append(error)
          }
        }
        return (configurations, errors)
      }
      
      groupedResults.whenSuccess { groupedResults in
        let errors = groupedResults.1
        for error in errors {
          parameters.logger.info("\(error.localizedDescription)")
        }
      }
      
      return parameters.database.transaction { database in
        let futureFeeds = groupedResults.map { $0.0 }.flatMapThrowing { urls -> [FeedConfiguration] in
          let decoder = JSONDecoder()
          let configs : [FeedConfiguration] = try urls.map{
            let data = try Data(contentsOf: $0)
            return try decoder.decode(FeedConfiguration.self, from: data)
          }
          let feeds = Dictionary(grouping: configs) { $0.channel.feedUrl }
          return feeds.compactMap { $0.value.first }
        }
        let currentChannels = futureFeeds.map { args -> [String] in
          args.map { $0.channel.feedUrl.absoluteString }
        }.flatMap { feedUrls in
          Channel.query(on: database).filter(\.$feedUrl ~~ feedUrls).with(\.$podcasts).all()
        }.map {
          Dictionary(uniqueKeysWithValues: ($0.map {
            ($0.feedUrl, $0)
          }))
        }
        
        let futureChannels = futureFeeds.and(currentChannels).flatMap { args -> EventLoopFuture<[ChannelFeedItemsConfiguration]> in
          parameters.logger.info("beginning upserting channels...")
          let (feeds, currentChannels) = args
          
          ///
          ///     let first = numbers[..<p]
          ///     // first == [30, 10, 20, 30, 30]
          ///     let second = numbers[p...]
          ///     // second == [60, 40]
          ///
          var allChanels = feeds.map { feedArgs in
            ChannelFeedItemsConfiguration(channels: currentChannels, feedArgs: feedArgs)
          }
          let index = allChanels.partition { $0.isNew  }
          
          let updatingChannels = allChanels[..<index].filter{$0.hasChanges}
          
          let updatingFutures = updatingChannels.map{
            $0.channel.update(on: database)
          }.flatten(on: eventLoop).transform(to: updatingChannels)
          
          let creatingChannels = allChanels[index...]
          
          let creatingFutures = creatingChannels.map{
            $0.channel
          }.create(on: database).transform(to: creatingChannels)
          
          
          return creatingFutures.and(updatingFutures).map{
            return $0.1 + $0.0
          }
        }
        //        }.flatMap { configurations -> EventLoopFuture<[ChannelFeedItemsConfiguration]> in
        //
        //          return configurations.map{
        //            $0.channel
        //          }.create(on: database).flatMapAlways{_ -> EventLoopFuture<[ChannelFeedItemsConfiguration]> in
        //            return context.eventLoop.future(configurations)
        //          }
        
        
        
        //          database.withConnection { database -> EventLoopFuture<[ChannelFeedItemsConfiguration]> in
        //
        //            var results = [EventLoopFuture<ChannelFeedItemsConfiguration?>]()
        //            let promise = context.eventLoop.makePromise(of: Void.self)
        //
        //            _ = context.eventLoop.scheduleRepeatedAsyncTask(
        //              initialDelay: .seconds(1),
        //              delay: .nanoseconds(20_000_000)
        //            ) { (task: RepeatedTask) -> EventLoopFuture<Void> in
        //              guard results.count < configurations.count else {
        //                task.cancel(promise: promise)
        //
        //                context.logger.info("finished upserting channels...")
        //                return context.eventLoop.makeSucceededFuture(())
        //              }
        //              let args = configurations[results.count]
        //
        //              context.logger.info("saving \"\(args.channel.title)\"")
        //              let result = args.channel.save(on: database).transform(to: args).flatMapError { _ -> EventLoopFuture<ChannelFeedItemsConfiguration?> in
        //                database.eventLoop.future(ChannelFeedItemsConfiguration?.none)
        //              }
        //              results.append(result)
        //              return result.transform(to: ())
        //            }
        //            let finalResults = promise.futureResult.flatMap {
        //              results.flatten(on: context.eventLoop).mapEachCompact { $0 }
        //            }
        //
        //            return finalResults
        //          }
        // }
        
        let podcastChannels = futureChannels.mapEachCompact { configuration -> Channel? in
          let hasPodcastEpisode = (configuration.items.first { $0.audio != nil }) != nil
          
          guard hasPodcastEpisode || configuration.channel.$category.id == "podcasts" else {
            return nil
          }
          if let podcasts = configuration.channel.$podcasts.value {
            guard podcasts.count == 0 else {
              return nil
            }
          }
          return configuration.channel
        }.flatMapEachCompact(on: eventLoop) { channel -> EventLoopFuture<PodcastChannel?> in
          parameters.client.get(Self.queryURL(forPodcastWithTitle: channel.title)).flatMapThrowing {
            try $0.content.decode(ApplePodcastResponse.self, using: parameters.decoder)
          }.map { response -> (PodcastChannel?) in
            response.results.first.flatMap { result in
              channel.id.map { ($0, result.collectionId) }
            }.map(PodcastChannel.init)
          }.recover { _ in nil }
        }.flatMapEach(on: eventLoop) { $0.create(on: database) }
        
        // save youtube channels to channels
        let futYTChannels = futureChannels.mapEachCompact { channel -> YouTubeChannel? in
          channel.youtubeChannel
        }.flatMapEach(on: database.eventLoop) { newChannel in
          YouTubeChannel.upsert(newChannel, on: database)
        }
        
        // save entries to channels
        let futureEntries = futureChannels
          .flatMapEachThrowing { try $0.feedItems() }
          .map { $0.flatMap { $0 } }
          .flatMapEach(on: database.eventLoop) { config -> EventLoopFuture<FeedItemEntry> in
            FeedItemEntry.from(upsertOn: database, from: config)
          }
        
        // save videos to entries
        
        let futYTVideos = futureEntries.flatMap { entries -> EventLoopFuture<[YoutubeVideo]> in
          let possibleVideos = entries
            .compactMap { $0.feedItem.ytId }
          
          parameters.logger.info("parsing \(possibleVideos.count) videos")
          
          return possibleVideos.chunked(by: 50)
            .map(Self.queryURL(forYouTubeWithIds:))
            .map { parameters.client.get($0) }
            .flatten(on: parameters.client.eventLoop)
            .flatMapEachThrowing { response in
              try response.content.decode(YouTubeResponse.self).items.map {
                (key: $0.id, value: $0.contentDetails.duration)
              }
            }.map { (arrays: [[(String, TimeInterval)]]) -> [(String, TimeInterval)] in
              arrays.flatMap { $0 }
            }.map([String: TimeInterval].init(uniqueKeysWithValues:)).map { durations in
              
              let youtubeVideos = entries.compactMap { entry -> YoutubeVideo? in
                guard let id = entry.entry.id else {
                  return nil
                }
                guard let youtubeId = entry.feedItem.ytId else {
                  return nil
                }
                guard let duration = durations[youtubeId] else {
                  return nil
                }
                return YoutubeVideo(entryId: id, youtubeId: youtubeId, seconds: Int(duration.rounded()))
              }
              parameters.logger.info("upserting \(youtubeVideos.count) videos")
              return youtubeVideos
            }
          
        }.recover { _ in [YoutubeVideo]() }
        .flatMapEach(on: database.eventLoop) { newVideo in
          YoutubeVideo.upsert(newVideo, on: database)
        }
        
        // save podcastepisodes to entries
        
        let futPodEpisodes = futureEntries.mapEachCompact { entry -> PodcastEpisode? in
          
          entry.podcastEpisode
        }.flatMapEach(on: database.eventLoop) { newEpisode in
          PodcastEpisode.upsert(newEpisode, on: database)
        }
        
        return futYTVideos.and(futYTChannels).and(futPodEpisodes).and(podcastChannels).and(channelCleanup).transform(to: ())
      }
    }
  }
}
