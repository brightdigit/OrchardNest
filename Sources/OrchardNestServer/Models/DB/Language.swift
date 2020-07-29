import Fluent
import Vapor

final class Language: Model {
  static var schema = "languages"

  init() {}

  init(code: String, title: String) {
    id = code
    self.title = title
  }

  @ID(custom: "code", generatedBy: .user)
  var id: String?

  @Field(key: "title")
  var title: String
}
