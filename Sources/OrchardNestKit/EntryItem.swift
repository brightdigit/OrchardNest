import Foundation

struct IncompleteCategoryType: Error {
  let type: EntryCategoryType
}

public enum EntryCategoryType: String, Codable {
  case companies
  case design
  case development
  case marketing
  case newsletters
  case podcasts
  case updates
  case youtube
}

struct EntryCategoryCodable: Codable {
  let type: EntryCategoryType
  let value: String?
  let seconds: Int?
}

public enum EntryCategory: Codable {
  public init(podcastEpisodeAtURL url: URL, withSeconds seconds: Int) {
    self = .podcasts(url, seconds)
  }

  public init(youtubeVideoWithID id: String, withSeconds seconds: Int) {
    self = .youtube(id, seconds)
  }

  public init(type: EntryCategoryType) throws {
    switch type {
    case .companies: self = .companies
    case .design: self = .design
    case .development: self = .development
    case .marketing: self = .marketing
    case .newsletters: self = .newsletters
    case .updates: self = .updates
    default:
      throw IncompleteCategoryType(type: type)
    }
  }

  public init(from decoder: Decoder) throws {
    let codable = try EntryCategoryCodable(from: decoder)

    switch codable.type {
    case .companies: self = .companies
    case .design: self = .design
    case .development: self = .development
    case .marketing: self = .marketing
    case .newsletters: self = .newsletters
    case .updates: self = .updates
    case .podcasts:
      guard let url = codable.value.flatMap(URL.init(string:)), let seconds = codable.seconds else {
        throw DecodingError.valueNotFound(URL.self, DecodingError.Context(codingPath: [], debugDescription: ""))
      }
      self = .podcasts(url, seconds)
    case .youtube:
      guard let id = codable.value, let seconds = codable.seconds else {
        throw DecodingError.valueNotFound(URL.self, DecodingError.Context(codingPath: [], debugDescription: ""))
      }
      self = .youtube(id, seconds)
    }
  }

  public func encode(to encoder: Encoder) throws {
    let codable = EntryCategoryCodable(type: type, value: value, seconds: seconds)
    try codable.encode(to: encoder)
  }

  case companies
  case design
  case development
  case marketing
  case newsletters
  case podcasts(URL, Int)
  case updates
  case youtube(String, Int)

  public var type: EntryCategoryType {
    switch self {
    case .companies: return .companies
    case .design: return .design
    case .development: return .development
    case .marketing: return .marketing
    case .newsletters: return .newsletters
    case .podcasts: return .podcasts
    case .updates: return .updates
    case .youtube: return .youtube
    }
  }

  var value: String? {
    switch self {
    case let .podcasts(url, _): return url.absoluteString
    case let .youtube(id, _): return id
    default: return nil
    }
  }

  var seconds: Int? {
    switch self {
    case let .podcasts(_, seconds): return seconds
    case let .youtube(_, seconds): return seconds
    default: return nil
    }
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
  public let category: EntryCategory

  public init(id: UUID,
              channel: EntryChannel,
              category: EntryCategory,
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
    self.category = category
    self.publishedAt = publishedAt
  }
}

public extension EntryItem {
  var seconds: Int? {
    if case let .youtube(_, seconds) = category {
      return seconds
    } else
    if case let .podcasts(_, seconds) = category {
      return seconds
    }
    return nil
  }

  var podcastEpisodeURL: URL? {
    if case let .podcasts(url, _) = category {
      return url
    }
    return nil
  }

  var youtubeID: String? {
    if case let .youtube(id, _) = category {
      return id
    }
    return nil
  }

  var twitterShareLink: String {
    let text = title + (channel.twitterHandle.map { " from @\($0)" } ?? "")
    return "https://twitter.com/intent/tweet?text=\(text)&via=orchardnest&url=\(url)"
  }

  var fallbackImageURL: URL? {
    return imageURL ?? channel.imageURL
  }
}
