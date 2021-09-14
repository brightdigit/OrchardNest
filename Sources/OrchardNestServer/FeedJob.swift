import Crypto
import Fluent
import FluentKit
import FluentPostgresDriver
import Foundation
import NIO
import Queues
import QueuesFluentDriver
import SyndiKit
import Vapor

struct MediaJobConfiguration: Codable {
  let channelIDs: [Channel.IDValue]
}

struct FeedSyncResponse {
  let isCompleted: Bool
  let mediaJobConfiguration: MediaJobConfiguration
}

struct FeedSyncConfiguration: Codable {}

extension Database {
  func create<EnumType: DatabaseEnum>(enum _: EnumType.Type) -> EventLoopFuture<DatabaseSchema.DataType> {
    var enumSchema = self.enum(EnumType.schema)
    for caseName in EnumType.allCases {
      enumSchema = enumSchema.case(EnumType.rawValue(caseName))
    }

    return enumSchema.create()
  }
}

struct EnumMigration<EnumType: DatabaseEnum>: Migration {
  func prepare(on database: Database) -> EventLoopFuture<Void> {
    database.create(enum: EnumType.self).transform(to: ())
  }

  func revert(on database: Database) -> EventLoopFuture<Void> {
    database.enum(EnumType.schema).delete()
  }

  var name: String {
    String(reflecting: EnumType.self)
  }
}

struct FeedResult {
  internal init(result: Result<Feedable, Error>, md5: Data?) {
    self.result = result
    self.md5 = md5
  }

  init(dataResult: Result<Data?, Error>, withDecoder decoder: SynDecoder) {
    if case let .failure(error) = dataResult {
      self.init(result: .failure(error), md5: nil)
      return
    }

    guard case let .success(.some(data)) = dataResult else {
      self.init(result: .failure(EmptyError()), md5: nil)
      return
    }

    let md5 = Data(Insecure.MD5.hash(data: data))
    let result = Result { try decoder.decode(data) }

    self.init(result: result, md5: md5)
  }

  let result: Result<Feedable, Error>
  let md5: Data?
}

// struct FeedDownload {
//  let feed: Result<Feedable, DecodingError>
//  let md5: Data
// }

extension Entry {
  func importFields(from entry: Entryable) {
    content = entry.contentHtml
    title = entry.title
    summary = entry.summary ?? summary

    url = entry.url.absoluteString
    imageURL = entry.imageURL?.absoluteString ?? imageURL
    publishedAt = entry.published ?? publishedAt
  }

  convenience init?(from entry: Entryable, channelId: UUID) {
    guard let summary = entry.summary, let published = entry.published else {
      return nil
    }
    self.init(channelId: channelId, feedId: entry.id.description, title: entry.title, summary: summary, content: entry.contentHtml, url: entry.url.absoluteString, imageURL: entry.imageURL?.absoluteString, publishedAt: published)
  }
}

extension QueueContext {
  var jobID: String? {
    return logger[metadataKey: "job_id"].flatMap { metadata -> String? in
      if case let .string(value) = metadata {
        return value
      }
      if case let Logger.MetadataValue.stringConvertible(value) = metadata {
        return value.description
      }
      return nil
    }
  }
}

struct FeedJob: Job {
  typealias Payload = FeedSyncConfiguration

  let decoder = SynDecoder()
  func downloadChannel(_ channel: Channel, withClient client: Client) -> EventLoopFuture<FeedResult> {
    let uri = URI(string: channel.feedUrl)
    return client.get(uri)
      .map { return $0.body.map { Data(buffer: $0) } }
      .flatMapAlways {
        client.eventLoop.future(FeedResult(dataResult: $0, withDecoder: decoder))
      }

//    let md5 = data.optionalMap(Insecure.MD5.hash).optionalMap { Data($0) }
//    let feed = data.optionalFlatMapThrowing { try decoder.decode($0) }
//
//    return data.and(md5.and(feed)).map { <#(Data?, (Data?, Feedable?))#> in
//      <#code#>
//    }
  }

  func dequeue(_ context: QueueContext, _: FeedSyncConfiguration) -> EventLoopFuture<Void> {
    guard let jobID = context.jobID else {
      return context.eventLoop.future(error: EmptyError())
    }
    return context.application.db.transaction { database in
      let updatingChannels = [
        Channel.query(on: database).filter(\.$publishedAt, .equality(inverse: false), nil).limit(80).all(),
        Channel.query(on: database).filter(\.$publishedAt, .equality(inverse: true), nil).sort(\.$publishedAt).limit(80).all()
      ].flatten(on: context.eventLoop).map {
        $0.flatMap { $0 }.prefix(100)
      }

      return updatingChannels.flatMapEachCompact(on: context.eventLoop) { channel -> EventLoopFuture<Channel.IDValue?> in
        let channelId: UUID
        do {
          channelId = try channel.requireID()
        } catch {
          return context.eventLoop.makeFailedFuture(error)
        }
        let download = self.downloadChannel(channel, withClient: context.application.client)
        return download.flatMap { (result: FeedResult) -> EventLoopFuture<Channel.IDValue?> in
          let saveFuture: EventLoopFuture<Void>
          let isSuccess: Bool
          if let md5 = result.md5 {
            channel.md5 = md5
          }
          channel.publishedAt = Date()
          switch result.result {
          case let .success(feed):
            let feedIDs = feed.children.map { $0.id.description }

            let youtubeSave: EventLoopFuture<Void>
            if let youtubeChannelID = feed.youtubeChannelID {
              youtubeSave = YouTubeChannel.upsert(YouTubeChannel(channelId: channelId, youtubeId: youtubeChannelID), on: database)
            } else {
              youtubeSave = context.eventLoop.future()
            }
            #warning("what if not unique")
            let currentEntriesF = channel.$entries
              .query(on: database)
              .filter(\.$feedId ~~ feedIDs)
              .all()
              .mapEach { ($0.feedId, $0) }
              .map { Dictionary(grouping: $0, by: { $0.0 }).compactMapValues { $0.first?.1 }}

            let entryUpdates = currentEntriesF.flatMap { currentEntries in
              feed.children.map { child -> EventLoopFuture<Void> in
                let entry: Entry?
                if let foundEntry = currentEntries[child.id.description] {
                  foundEntry.importFields(from: child)
                  entry = foundEntry
                } else {
                  entry = Entry(from: child, channelId: channelId)
                }
                guard let entry = entry else {
                  return context.eventLoop.future()
                }
                return entry.save(on: database)
              }.flatten(on: context.eventLoop)
            }

            if let author = feed.authors.first {
              channel.author = author.name
              channel.email = author.email
            } else {
              channel.author = channel.author
            }
            
            channel.imageURL = feed.image?.absoluteString ?? channel.imageURL
            channel.subtitle = channel.subtitle ?? feed.summary

            saveFuture = entryUpdates.and(youtubeSave).transform(to: ())
            isSuccess = true
          case let .failure(error):
            let type: ChannelFailureType

            switch (result.md5, error is EmptyError) {
            case (.none, true):
              type = .missing
            case (.none, false):
              type = .download
            case (.some, _):
              type = .decoding
            }

            let channelFailure = ChannelFailure(channelId: channelId, type: type, jobID: jobID, failure: error)
            saveFuture = channelFailure.save(on: database)
            isSuccess = false
          }
          return channel.update(on: database).and(saveFuture).transform(to: isSuccess ? channelId : nil)
//          guard channel.md5 != download.md5 else {
//            return context.eventLoop.future(())
//          }
//          let feed = download.feed
//
//          let feedIDs = feed.children.map { $0.id.description }
//
//          let currentEntriesF = channel.$entries
//            .query(on: database)
//            .filter(\.$feedId ~~ feedIDs)
//            .all()
//            .mapEach { ($0.feedId, $0) }
//            .map(Dictionary.init(uniqueKeysWithValues:))
//
//          let entryUpdates = currentEntriesF.flatMap { currentEntries in
//            feed.children.map { child -> EventLoopFuture<Void> in
//              let entry: Entry?
//              if let foundEntry = currentEntries[child.id.description] {
//                foundEntry.importFields(from: child)
//                entry = foundEntry
//              } else {
//                entry = Entry(from: child, channelId: channelId)
//              }
//              guard let entry = entry else {
//                return context.eventLoop.future()
//              }
//              return entry.save(on: database)
//            }.flatten(on: context.eventLoop)
//          }
//
//          channel.author = feed.author?.name ?? channel.author
//          channel.email = feed.author?.email
//          channel.imageURL = feed.image?.absoluteString ?? channel.imageURL
//          channel.subtitle = channel.subtitle ?? feed.summary
//
//          channel.md5 = download.md5
//          channel.publishedAt = Date()
//          return entryUpdates.and(channel.update(on: database)).transform(to: ())
        }
      }.flatMap { channelIDs in
        Channel.query(on: context.application.db).group(.or) {
          $0.filter(\.$publishedAt == nil).filter(\.$publishedAt < Date(timeIntervalSinceNow: 60 * 60 * 3))
        }.count().map { $0 <= 0 }.map {
          FeedSyncResponse(isCompleted: $0, mediaJobConfiguration: MediaJobConfiguration(channelIDs: channelIDs))
        }
      }.flatMap { response in
        var dispatchedJobs = [EventLoopFuture<Void>]()
        if !response.isCompleted {
          dispatchedJobs.append(context.queue.dispatch(
            FeedJob.self,
            FeedSyncConfiguration()
          ))
        }

        return dispatchedJobs.flatten(on: context.eventLoop)
      }
    }
  }
}
