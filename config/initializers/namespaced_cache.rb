module QPixel
  class NamespacedEnvCache < ActiveSupport::Cache::Store
    def initialize(underlying)
      @underlying = underlying
    end

    # These methods need the cache key name updating before we pass it to the underlying cache.
    [:decrement, :delete, :exist?, :fetch, :increment, :read, :write].each do |method|
      define_method method do |name, *args, **opts, &block|
        @underlying.send(method, "#{Rails.env}://#{name}", *args, **opts, &block)
      end
    end

    # These methods need a hash of cache keys updating before we pass it to the underlying cache.
    [:fetch_multi, :read_multi, :write_multi].each do |method|
      define_method method do |hash, *args, **opts, &block|
        hash = hash.map { |k, v| ["#{Rails.env}://#{k}", v] }.to_h
        @underlying.send(method, hash, *args, **opts, &block)
      end
    end

    # These methods can be passed straight-through to the underlying cache.
    [:cleanup, :clear, :key_matcher, :mute, :silence!].each do |method|
      define_method method do |*args, **opts, &block|
        @underlying.send(method, *args, **opts, &block)
      end
    end

    # This can't easily be supported, matchers are hard to update for a new name.
    def delete_matched
      raise NotImplementedError, "#{self.class} does not support delete_matched"
    end
  end
end

Rails.cache = QPixel::NamespacedEnvCache.new(Rails.cache)

# Write persistent values to cache on startup
Rails.cache.write 'post_type_ids', PostType.all.map { |pt| [pt.name, pt.id] }.to_h
Rails.cache.write 'current_commit', "#{`git rev-parse HEAD`.strip[0..7]} (#{`git log -1 --date=iso --pretty=format:%cd`.strip})"