import Fluent
import Vapor

final class YoutubeVideo: Model {
  static var schema = "youtube_videos"

  init() {}

  init(entryId: UUID, youtubeId: String) {
    id = entryId
    self.youtubeId = youtubeId
  }

  @ID(custom: "entry_id", generatedBy: .user)
  var id: UUID?

  @Field(key: "youtube_id")
  var youtubeId: String
}
