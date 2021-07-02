import Crypto
import Foundation
import Queues
import SyndiKit
import Vapor

struct FeedSyncConfiguration: Codable {}

struct FeedJob: Job {
  let decoder = RSSDecoder()
  func downloadChannel(_ channel: Channel, withClient _: Client) {
    let uri = URI(string: channel.feedUrl)
    // client.get(uri).optionalMap(Data.init(buffer:))
  }

  func dequeue(_ context: QueueContext, _: FeedSyncConfiguration) -> EventLoopFuture<Void> {
    let updatingChannels = [
      Channel.query(on: context.application.db).filter(\.$publishedAt, .equality(inverse: false), nil).limit(80).all(),
      Channel.query(on: context.application.db).filter(\.$publishedAt, .equality(inverse: true), nil).sort(\.$publishedAt).limit(80).all()
    ].flatten(on: context.eventLoop).map {
      $0.flatMap { $0 }.prefix(100)
    }
    return context.eventLoop.future()
  }
}
