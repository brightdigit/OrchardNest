import Fluent
import Vapor

final class PodcastEpisode: Model {
  static var schema = "podcast_episodes"

  init() {}

  init(entryId: UUID, audioURL: URL) {
    id = entryId
    self.audioURL = audioURL
  }

  @ID(custom: "entry_id", generatedBy: .user)
  var id: UUID?

  @Field(key: "audio")
  var audioURL: URL
}
