import Foundation

class EntryChannel: Codable {
  let id: UUID
  var title: String
  var language: String
  var category: String
  var subtitle: String?
  var author: String
  var siteUrl: URL
  var feedUrl: URL
  var twitterHandle: String?
  var imageURL: String?
}

class EntryItem: Codable {
  var id: UUID
  var channel: EntryChannel
  var feedId: String
  var title: String
  var summary: String
  var url: URL
  var imageURL: URL?
  var publishedAt: Date
}
