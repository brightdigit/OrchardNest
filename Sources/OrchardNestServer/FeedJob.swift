import Crypto
import Foundation
import Queues
import SyndiKit
import Vapor

struct FeedSyncConfiguration: Codable {}

struct FeedDownload {
  let feed: Feedable
  let md5 : Data
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
    let id = context.logger[metadataKey: "job_id"].flatMap{ (metadata) -> String? in
      if case let .string(value) = metadata {
        return value
      }
      if case let Logger.MetadataValue.stringConvertible(value) = metadata {
        return value.description
      }
      return nil
    }
    
    print(id)
    
    
    let updatingChannels = [
      Channel.query(on: context.application.db).filter(\.$publishedAt, .equality(inverse: false), nil).limit(80).all(),
      Channel.query(on: context.application.db).filter(\.$publishedAt, .equality(inverse: true), nil).sort(\.$publishedAt).limit(80).all()
    ].flatten(on: context.eventLoop).map {
      $0.flatMap { $0 }.prefix(100)
    }
    
//    updatingChannels.flatMapEach(on: context.eventLoop, { channel in
//      
//      let download = self.downloadChannel(channel, withClient: context.application.client)
//      return download.optionalFlatMap({ (download : FeedDownload) in
//        guard channel.md != download.md5 else {
//          return context.eventLoop.future(nil)
//        }
//        let feed = download.feed
//        
//        channel.author = channel.author ?? feed.author?.name
//        channel.email = feed.author?.email
//        channel.imageURL = channel.imageURL ?? feed.image
//        channel.subtitle = channel.subtitle ?? feed.summary
//        
//        channel.md5 = download.md5
//        channel.publishedAt = Date()
//      })
//    })
    return context.eventLoop.future()
  }
}
