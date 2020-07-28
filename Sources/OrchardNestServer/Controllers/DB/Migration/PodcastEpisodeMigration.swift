import Fluent
import Vapor

struct PodcastEpisodeMigration: Migration {
  func prepare(on database: Database) -> EventLoopFuture<Void> {
    database.schema(PodcastEpisode.schema)
      .field("entry_id", .uuid, .references(Entry.schema, .id))
      .field("audio", .string, .required)
      .create()
  }

  func revert(on database: Database) -> EventLoopFuture<Void> {
    database.schema(PodcastEpisode.schema).delete()
  }
}