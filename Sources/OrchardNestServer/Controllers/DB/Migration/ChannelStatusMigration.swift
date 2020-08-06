import Fluent
import Vapor

struct ChannelStatusMigration: Migration {
  func prepare(on database: Database) -> EventLoopFuture<Void> {
    var channel_status_type = database.enum("channel_status_type")
    for type in ChannelStatusType.allCases {
      channel_status_type = channel_status_type.case(type.rawValue)
    }
    return channel_status_type.create().flatMap { channel_status_type in

      database.schema(ChannelStatus.schema)
        .field("feed_url", .uuid, .identifier(auto: false))
        .field("status", channel_status_type, .required)
        .create()
    }
  }

  func revert(on database: Database) -> EventLoopFuture<Void> {
    database.schema(ChannelStatus.schema).delete()
  }
}
