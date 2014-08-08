#!/usr/bin/env ruby
# rubocop:disable LineLength,MethodLength
require 'English'
require 'net/http'
require 'fileutils'
require 'rexml/document'
require 'awesome_print'

# Simple downloader to track changes
module Bento
  BUCKET_HOST = 'opscode-vm-bento.s3.amazonaws.com'

  # A single Content item
  class Item
    include Comparable

    attr_reader :path, :etag, :os, :version, :bitness

    def initialize(path, etag)
      @path, @etag = path, etag

      fail "Unable to match #{filename}" unless filename =~ /\Aopscode_([a-z]+)-([0-9.]+)(-i386|-x86_64|)_chef-provisionerless.box\Z/
      @os = Regexp.last_match[1]
      @version = Gem::Version.new Regexp.last_match[2]
      @bitness = Regexp.last_match[3] == '-i386' ? 32 : 64
    end

    def url
      "http://#{BUCKET_HOST}/#{path}"
    end

    def filename
      File.basename path
    end

    def <=>(other)
      return 0 if other.path == path && other.etag == etag

      os <=> other.os || version <=> other.version || bitness <=> other.bitness
    end

    def to_s
      "#{os}-#{version} #{bitness}bit"
    end
  end

  # Downloader
  class Lister
    def baseurl
      URI.parse("http://#{BUCKET_HOST}")
    end

    def doc
      @doc ||= REXML::Document.new Net::HTTP.get_response(baseurl).body
    end

    def list
      REXML::XPath.match(doc, '/ListBucketResult/Contents')
        .select { |e| e.elements['Key'].text =~ %r{\Avagrant/virtualbox/.*\.box\Z} }
        .map { |e| Item.new e.elements['Key'].text, e.elements['ETag'].text }
    end

    def latest(os, requires = '>= 0', bits = 32)
      requirement = Gem::Requirement.new requires
      list
        .select { |i| i.os == os }
        .select { |i| i.bitness == bits }
        .select { |i| requirement.satisfied_by? i.version }
        .sort
        .last
    end
  end

  # Fetcher downloads the file(s)
  class Fetcher
    attr_reader :item

    def initialize(item)
      @item = item.freeze
    end

    def etag_path
      "#{path}.etag"
    end

    def path
      item.path
    end

    def up_to_date?
      @up_to_date ||= File.exist?(path) && File.exist?(etag_path) && File.read(etag_path) == item.etag
    end

    def save_etag
      ensure_directory

      File.write(etag_path, item.etag)
    end

    def ensure_directory
      FileUtils.makedirs File.dirname(path) unless File.directory? path
    end

    def run
      return if up_to_date?
      ensure_directory

      tmp_path = File.join File.dirname(path),  ".tmp.#{File.basename path}"
      args = %W(curl -s -q -L -o #{tmp_path} #{item.url})
      if system(*args)
        begin
          File.rename(tmp_path, path)
        rescue
          File.unlink(tmp_path) if File.exist?(tmp_path)
          raise
        end
        save_etag
      else
        puts "Failed to download #{item}: exit code #{$CHILD_STATUS}"
        File.unlink(etag_path) if File.exist?(etag_path)
      end
    end
  end
end

bento = Bento::Lister.new

items = [
  ['centos', '~> 5.0'],
  ['centos', '~> 6.0'],
  ['centos', '~> 7.0'],
  ['ubuntu', '14.04'],
  ['debian', '~> 7.0']
].map do |os, ver|
  [32, 64].map { |b| bento.latest(os, ver, b) }
end.flatten.compact.sort

items.each do |item|
  puts format('%-8s %-5s %2sbit -> %s', item.os, item.version, item.bitness, item.path)
  Bento::Fetcher.new(item).run unless ARGV.include?('-n')
end
