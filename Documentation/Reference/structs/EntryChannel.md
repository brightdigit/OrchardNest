**STRUCT**

# `EntryChannel`

```swift
public struct EntryChannel: Codable
```

## Properties
### `id`

```swift
public let id: UUID
```

### `title`

```swift
public let title: String
```

### `author`

```swift
public let author: String
```

### `siteURL`

```swift
public let siteURL: URL
```

### `twitterHandle`

```swift
public let twitterHandle: String?
```

### `imageURL`

```swift
public let imageURL: URL?
```

### `podcastAppleId`

```swift
public let podcastAppleId: Int?
```

## Methods
### `init(id:title:siteURL:author:twitterHandle:imageURL:podcastAppleId:)`

```swift
public init(
  id: UUID,
  title: String,
  siteURL: URL,
  author: String,
  twitterHandle: String?,
  imageURL: URL?,
  podcastAppleId: Int?
)
```
