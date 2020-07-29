import Fluent
import Vapor

final class Category: Model {
  static var schema = "categories"

  init() {}

  init(slug: String) {
    id = slug
  }

  @ID(custom: "slug", generatedBy: .user)
  var id: String?
}
