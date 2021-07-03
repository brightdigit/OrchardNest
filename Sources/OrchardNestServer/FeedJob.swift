import Crypto
import Foundation
import Queues
import SyndiKit
import Vapor
import Fluent
struct FeedSyncConfiguration: Codable {}

struct FeedDownload {
  let feed: Feedable
  let md5 : Data
}

extension Entry {
  func importFields(from entry: Entryable) {
    self.content = entry.contentHtml
    self.title = entry.title
    self.summary = entry.summary ?? self.summary
    
    self.url = entry.url.absoluteString
    self.imageURL = entry.imageURL?.absoluteString ?? self.imageURL
    self.publishedAt = entry.published ?? self.publishedAt
  }
  
  convenience init?(from entry: Entryable) {
    guard let summary = entry.summary, let published = entry.published else {
      return nil
    }
    self.init(feedId: entry.id.description, title: entry.title, summary: summary, content: entry.contentHtml, url: entry.url.absoluteString, imageURL: entry.imageURL?.absoluteString, publishedAt: published)
  }
}

extension QueueContext {
  var jobID: String? {
    return self.logger[metadataKey: "job_id"].flatMap{ (metadata) -> String? in
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
  
  
  let decoder = RSSDecoder()
  func downloadChannel(_ channel: Channel, withClient client: Client) -> EventLoopFuture<FeedDownload?> {
  
    let uri = URI(string: channel.feedUrl)
    return client.get(uri).map{$0.body}.optionalMap{
      Data(buffer: $0)
    }.optionalFlatMapThrowing{ (data) in
      try FeedDownload(feed: decoder.decode(data), md5: Data(Insecure.MD5.hash(data: data)))
    }
    
    
  
  }
//  public func _dequeue(_ context: QueueContext, id: String, payload: [UInt8]) -> EventLoopFuture<Void> {
//      var contextCopy = context
//      contextCopy.logger[metadataKey: "job_id"] = .string(id)
//
//      do {
//          return try self.dequeue(contextCopy, Self.parsePayload(payload))
//      } catch {
//          return context.eventLoop.makeFailedFuture(error)
//      }
//  }
  
  func dequeue(_ context: QueueContext, _ config: FeedSyncConfiguration) -> EventLoopFuture<Void> {
    
    return context.application.db.transaction { database in
      let updatingChannels = [
        Channel.query(on: database).filter(\.$publishedAt, .equality(inverse: false), nil).limit(80).all(),
        Channel.query(on: database).filter(\.$publishedAt, .equality(inverse: true), nil).sort(\.$publishedAt).limit(80).all()
      ].flatten(on: context.eventLoop).map {
        $0.flatMap { $0 }.prefix(100)
      }
      
      return updatingChannels.flatMapEach(on: context.eventLoop, { channel  -> EventLoopFuture<Void?> in
        
        let download = self.downloadChannel(channel, withClient: context.application.client)
        return download.optionalFlatMap({ (download : FeedDownload) -> EventLoopFuture<Void> in
          guard channel.md5 != download.md5 else {
            return context.eventLoop.future(())
          }
          let feed = download.feed
          
          let feedIDs = feed.children.map{ $0.id.description }
          
          let currentEntriesF = channel.$entries
            .query(on: database)
            .filter(\.$feedId ~~ feedIDs)
            .all()
            .mapEach{ ($0.feedId, $0) }
            .map(Dictionary.init(uniqueKeysWithValues:))
          
          let entryUpdates = currentEntriesF.flatMap{ (currentEntries) in
            feed.children.map{ (child) -> EventLoopFuture<Void> in
              let entry : Entry?
              if let foundEntry = currentEntries[child.id.description] {
                foundEntry.importFields(from: child)
                entry = foundEntry
              } else {
                entry = Entry(from: child)
              }
              guard let entry = entry else {
                return context.eventLoop.future()
              }
              return entry.update(on: database)
            }.flatten(on: context.eventLoop)
          }
          
          channel.author = feed.author?.name ?? channel.author
          channel.email = feed.author?.email
          channel.imageURL = feed.image?.absoluteString ?? channel.imageURL
          channel.subtitle = channel.subtitle ?? feed.summary
          
          channel.md5 = download.md5
          channel.publishedAt = Date()
          return entryUpdates.and(channel.update(on: database)).transform(to: ())
        })
      }).transform(to: ())
    }
    
    
    
  }
}
