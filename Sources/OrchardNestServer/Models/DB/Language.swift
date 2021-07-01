import Fluent
import Vapor
import SyndiKit

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

extension Language {
  static func from(_ language: SyndiKit.Language, on database: Database)-> EventLoopFuture<Language> {
    Language.find(language.type, on: database).flatMap{ languageDB in
      let updatedLangDB: Language
      if let languageDB = languageDB {
        languageDB.title = language.title
        updatedLangDB = languageDB
      } else {
        updatedLangDB = Language(code: language.type, title: language.title)
      }
      return updatedLangDB.save(on: database).transform(to: updatedLangDB)
    }
  }
//  static func from(_ pair: (String, String), on database: Database) -> EventLoopFuture<Language> {
//    Language.find(pair.0, on: database).flatMap { langOpt -> EventLoopFuture<Language> in
//      let language: Language
//      if let actual = langOpt {
//        actual.title = pair.1
//        language = actual
//      } else {
//        language = Language(code: pair.0, title: pair.1)
//      }
//      return language.save(on: database).transform(to: language)
//    }
//  }
}
