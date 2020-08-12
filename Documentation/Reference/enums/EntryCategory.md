**ENUM**

# `EntryCategory`

```swift
public enum EntryCategory: Codable
```

## Cases
### `companies`

```swift
case companies
```

### `design`

```swift
case design
```

### `development`

```swift
case development
```

### `marketing`

```swift
case marketing
```

### `newsletters`

```swift
case newsletters
```

### `podcasts(_:_:)`

```swift
case podcasts(URL, TimeInterval?)
```

### `updates`

```swift
case updates
```

### `youtube(_:_:)`

```swift
case youtube(String, TimeInterval?)
```

## Properties
### `type`

```swift
public var type: EntryCategoryType
```

## Methods
### `init(podcastEpisodeAtURL:withDuration:)`

```swift
public init(podcastEpisodeAtURL url: URL, withDuration duration: TimeInterval?)
```

### `init(youtubeVideoWithID:withDuration:)`

```swift
public init(youtubeVideoWithID id: String, withDuration duration: TimeInterval?)
```

### `init(type:)`

```swift
public init(type: EntryCategoryType) throws
```

### `init(from:)`

```swift
public init(from decoder: Decoder) throws
```

#### Parameters

| Name | Description |
| ---- | ----------- |
| decoder | The decoder to read data from. |

### `encode(to:)`

```swift
public func encode(to encoder: Encoder) throws
```

#### Parameters

| Name | Description |
| ---- | ----------- |
| encoder | The encoder to write data to. |