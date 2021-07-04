import Fluent
import Vapor

final class CategoryTitle: Model {
  static var schema = "category_titles"

  init() {}

  init(id: UUID? = nil, language: Language, category: Category) throws {
    self.id = id
    $category.id = try category.requireID()
    $language.id = try language.requireID()
  }

  init(languageCode: Language.IDValue, categorySlug: Category.IDValue, title: String, description _: String) {
    $category.id = categorySlug
    $language.id = languageCode
    self.title = title
  }

  @ID()
  var id: UUID?

  @Parent(key: "code")
  var language: Language

  @Parent(key: "slug")
  var category: Category

  @Field(key: "title")
  var title: String

  @OptionalField(key: "description")
  var description: String?
}
