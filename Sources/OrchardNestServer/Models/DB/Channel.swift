import Fluent
import Vapor
import SyndiKit

public final class Channel: Model {
  public static var schema = "channels"

  public init() {
  }
  @ID()
  public var id: UUID?

  @Field(key: "title")
  var title: String

  @Parent(key: "language_code")
  var language: Language

  @Parent(key: "category_slug")
  var category: Category

  @OptionalField(key: "subtitle")
  var subtitle: String?

  @Field(key: "author")
  var author: String

  @Field(key: "site_url")
  var siteUrl: String

  @Field(key: "feed_url")
  var feedUrl: String

  @OptionalField(key: "twitter_handle")
  var twitterHandle: String?

  @OptionalField(key: "image")
  var imageURL: String?

  @OptionalField(key: "published_at")
  var publishedAt: Date?

  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  
  @Timestamp(key: "updated_at", on: .update)
  var updatedAt: Date?

  @Children(for: \.$channel)
  var entries: [Entry]

  @Children(for: \.$channel)
  var podcasts: [PodcastChannel]

  @Children(for: \.$channel)
  var youtubeChannels: [YouTubeChannel]
}

extension Channel: Validatable {
  public static func validations(_ validations: inout Validations) {
    validations.add("siteUrl", as: URL.self)
    validations.add("feedUrl", as: URL.self)
    validations.add("imageURL", as: URL.self)
  }
}

extension Channel {
  public convenience init(fromBlogSite site: BlogSite) {
    self.init()
    self.$category.id = site.category
    self.$language.id = site.language
    self.feedUrl = site.feedURL.absoluteString
    self.siteUrl = site.siteURL.absoluteString
    self.twitterHandle = site.twitterURL?.lastPathComponent
    self.title = site.title
    self.author = site.author
    
  }
}

extension UUID {
  var base32Encoded: String {
    // swiftlint:disable:next force_cast
    let bytes = Mirror(reflecting: uuid).children.map { $0.value as! UInt8 }
    return Data(bytes).base32EncodedString()
  }
}

extension String {
  var base32UUID: UUID? {
    guard let data = Data(base32Encoded: self) else {
      return nil
    }
    var bytes = [UInt8](repeating: 0, count: data.count)
    _ = bytes.withUnsafeMutableBufferPointer {
      data.copyBytes(to: $0)
    }
    return NSUUID(uuidBytes: bytes) as UUID
  }
}
