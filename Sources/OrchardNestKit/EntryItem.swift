import Foundation

public struct EntryChannel: Codable {
  let id: UUID
  let title: String
  let author: String
  let twitterHandle: String?
  let imageURL: URL?

  public init(
    id: UUID,
    title: String,
    author: String,
    twitterHandle: String?,
    imageURL: URL?
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.twitterHandle = twitterHandle
    self.imageURL = imageURL
  }
}

public struct EntryItem: Codable {
  let id: UUID
  let channel: EntryChannel
  let feedId: String
  let title: String
  let summary: String
  let url: URL
  let imageURL: URL?
  let publishedAt: Date

  public init(id: UUID,
              channel: EntryChannel,
              feedId: String,
              title: String,
              summary: String,
              url: URL,
              imageURL: URL?,
              publishedAt: Date) {
    self.id = id
    self.channel = channel
    self.feedId = feedId
    self.title = title
    self.summary = summary
    self.url = url
    self.imageURL = imageURL
    self.publishedAt = publishedAt
  }
}
