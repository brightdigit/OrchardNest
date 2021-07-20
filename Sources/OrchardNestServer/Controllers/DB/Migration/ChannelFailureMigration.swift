import Fluent
import Vapor

struct ChannelFailureMigration: Migration {
  func prepare(on database: Database) -> EventLoopFuture<Void> {
    database.enum(ChannelFailureType.schema).read().flatMap { typeEnum in
      database.schema(ChannelFailure.schema)
        .id()
        .field("channel_id", .uuid, .references(Channel.schema, .id))
        .field("job_id", .string, .required)
        .field("type", typeEnum, .required)
        .field("description", .string, .required)
        .field("created_at", .datetime, .required)
        .create()
    }
  }

  func revert(on database: Database) -> EventLoopFuture<Void> {
    database.schema(ChannelFailure.schema).delete()
  }
}
