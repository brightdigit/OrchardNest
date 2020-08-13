import Fluent
import OrchardNestKit
import Vapor

struct InvalidURLFormat: Error {}

extension String {
  func asURL() throws -> URL {
    guard let url = URL(string: self) else {
      throw InvalidURLFormat()
    }
    return url
  }
}

extension Entry {
  func category() throws -> EntryCategory {
    guard let category = EntryCategoryType(rawValue: channel.$category.id) else {
      return .development
    }

    if let podcastEpisode = self.podcastEpisode, let url = URL(string: podcastEpisode.audioURL) {
      return .podcasts(url, podcastEpisode.seconds)
    } else if let youtubeVideo = self.youtubeVideo {
      return .youtube(youtubeVideo.youtubeId, youtubeVideo.seconds)
    } else {
      return try EntryCategory(type: category)
    }
  }
}

extension EntryChannel {
  init(channel: Channel) throws {
    try self.init(
      id: channel.requireID(),
      title: channel.title,
      siteURL: channel.siteUrl.asURL(),
      author: channel.author,
      twitterHandle: channel.twitterHandle,
      imageURL: channel.imageURL?.asURL(),
      podcastAppleId: channel.$podcasts.value?.first?.appleId
    )
  }
}

extension EntryItem {
  init(entry: Entry) throws {
    try self.init(
      id: entry.requireID(),
      channel: EntryChannel(channel: entry.channel),
      category: entry.category(),
      feedId: entry.feedId,
      title: entry.title,
      summary: entry.summary,
      url: entry.url.asURL(),
      imageURL: entry.imageURL?.asURL(),
      publishedAt: entry.publishedAt
    )
  }
}

struct EntryController {
  static func entries(from database: Database) -> QueryBuilder<Entry> {
    return Entry.query(on: database).with(\.$channel) { builder in
      builder.with(\.$podcasts).with(\.$youtubeChannels)
    }
    .join(parent: \.$channel)
    .with(\.$podcastEpisodes)
    .join(children: \.$podcastEpisodes, method: .left)
    .with(\.$youtubeVideos)
    .join(children: \.$youtubeVideos, method: .left)
    .sort(\.$publishedAt, .descending)
  }

  func list(req: Request) -> EventLoopFuture<Page<EntryItem>> {
    return Self.entries(from: req.db)
      .paginate(for: req)
      .flatMapThrowing { (page: Page<Entry>) -> Page<EntryItem> in
        try page.map { (entry: Entry) -> EntryItem in
          try EntryItem(entry: entry)
        }
      }
  }

  func latest(req: Request) -> EventLoopFuture<Page<EntryItem>> {
    return Self.entries(from: req.db)
      .join(LatestEntry.self, on: \Entry.$id == \LatestEntry.$id)
      .filter(Channel.self, \Channel.$category.$id != "updates")
      .filter(Channel.self, \Channel.$language.$id == "en")
      .paginate(for: req)
      .flatMapThrowing { (page: Page<Entry>) -> Page<EntryItem> in
        try page.map { (entry: Entry) -> EntryItem in
          try EntryItem(entry: entry)
        }
      }
  }
}

extension EntryController: RouteCollection {
  func boot(routes: RoutesBuilder) throws {
    routes.get("", use: list)
    routes.get("latest", use: latest)
  }
}
