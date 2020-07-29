import Fluent
import Vapor

final class YouTubeChannel: Model {
  static var schema = "youtube_channels"

  init() {}

  init(channelId: UUID, youtubeId: String) {
    id = channelId
    self.youtubeId = youtubeId
  }

  @ID(custom: "channel_id", generatedBy: .user)
  var id: UUID?

  @Field(key: "youtube_id")
  var youtubeId: String
}
