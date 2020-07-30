import Fluent
import Vapor

final class PodcastEpisode: Model {
  static var schema = "podcast_episodes"

  init() {}

  init(entryId: UUID, audioURL: String) {
    id = entryId
    self.audioURL = audioURL
  }

  @ID(custom: "entry_id", generatedBy: .user)
  var id: UUID?

  @Field(key: "audio")
  var audioURL: String
}

extension PodcastEpisode: Validatable {
  static func validations(_ validations: inout Validations) {
    validations.add("audioURL", as: URL.self)
  }
}
