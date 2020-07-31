import Foundation

public struct EntryChannel: Codable {
  public let id: UUID
  public let title: String
  public let author: String
  public let twitterHandle: String?
  public let imageURL: URL?

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
  public let id: UUID
  public let channel: EntryChannel
  public let feedId: String
  public let title: String
  public let summary: String
  public let url: URL
  public let imageURL: URL?
  public let publishedAt: Date

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
