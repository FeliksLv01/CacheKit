Pod::Spec.new do |spec|
  spec.name = 'CacheKit'
  spec.version = '0.1.0'
  spec.summary = 'A high-performance memory, disk, and file cache for Swift.'
  spec.description = <<-DESC
    CacheKit provides synchronous and async memory, disk, hybrid, and file caches,
    with LRU eviction, expiration, batching, deduplication, and single-flight loading.
  DESC
  spec.homepage = 'https://github.com/FeliksLv01/CacheKit'
  spec.license = { type: 'MIT', file: 'LICENSE' }
  spec.authors = { 'FeliksLv' => 'felikslv@163.com' }
  spec.source = { git: 'https://github.com/FeliksLv01/CacheKit.git', tag: spec.version.to_s }

  spec.ios.deployment_target = '15.0'
  spec.swift_version = '6.0'
  spec.source_files = 'Sources/CacheKit/**/*.swift'
  spec.libraries = 'sqlite3'

  spec.test_spec 'Tests' do |tests|
    tests.source_files = 'Tests/**/*.swift'
  end
end
