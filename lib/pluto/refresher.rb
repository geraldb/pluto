module Pluto

class Refresher

  include LogUtils::Logging

  include Models

  def initialize
    @worker  = ::Fetcher::Worker.new
  end

  attr_reader :worker

  def debug=(value)
    @debug = value
    ### logger.debug "[Updater] setting debug flag - debug? #{debug?}"
  end

  def debug?
    @debug || false
  end

  def fetch_feed( url )
    
    ### fix: use worker.get( url )  # check http response code etc.
    
    xml = worker.read( url )

    ###
    # NB: Net::HTTP will NOT set encoding UTF-8 etc.
    # will mostly be ASCII
    # - try to change encoding to UTF-8 ourselves
    logger.debug "xml.encoding.name (before): #{xml.encoding.name}"

    #####
    # NB: ASCII-8BIT == BINARY == Encoding Unknown; Raw Bytes Here

    ## NB:
    # for now "hardcoded" to utf8 - what else can we do?
    # - note: force_encoding will NOT change the chars only change the assumed encoding w/o translation
    xml = xml.force_encoding( Encoding::UTF_8 )
    logger.debug "xml.encoding.name (after): #{xml.encoding.name}"      
    xml
  end


  def update_feeds( opts={} )

    if debug?
      ## turn on logging for sql too
      ActiveRecord::Base.logger = Logger.new( STDOUT )
    end

    ### move to feedutils
    ### logger.debug "using stdlib RSS::VERSION #{RSS::VERSION}"

    # -- log update action
    Action.create!( title: 'update feeds' )

    #####
    # -- update fetched_at  timestamps for all sites
    feeds_fetched_at = Time.now
    Site.all.each do |site|
      site.fetched_at = feeds_fetched_at
      site.save!
    end

    Feed.all.each do |feed_rec|

      feed_key = feed_rec.key
      feed_url = feed_rec.feed_url
      
      feed_xml = fetch_feed( feed_url )

      logger.debug "feed_xml:"
      logger.debug feed_xml[ 0..300 ] # get first 300 chars

      #  if opts.verbose?  # also write a copy to disk
      if debug?
        logger.debug "saving feed to >./#{feed_key}.xml<..."
        File.open( "./#{feed_key}.xml", 'w' ) do |f|
          f.write( feed_xml )
        end
      end
      
      puts "Before parsing feed >#{feed_key}<..."

      ## fix/todo: check for feed.nil?   -> error parsing!!!
      #    or throw exception
      feed = FeedUtils::Parser.parse( feed_xml )

      feed_fetched_at = Time.now

      ## todo/check: move feed_rec update to the end (after item updates??)

      # update feed attribs e.g.
      #    generator
      #    published_at,built_at,touched_at,fetched_at
      #    summary,title2
      
      ## fix:
      ## weird rss exception error on windows w/ dates
      #  e.g. /lib/ruby/1.9.1/rss/rss.rb:37:in `w3cdtf': wrong number of arguments (1 for 0) (ArgumentError)
      #
      #  move to_datetime to feedutils!! if it works
      ##   todo: move this comments to feedutils??
      
      
      feed_attribs = {
        fetched_at:   feed_fetched_at,
        format:       feed.format,
        published_at: feed.published? ? feed.published : nil,
        touched_at:   feed.updated?   ? feed.updated   : nil,
        built_at:     feed.built?     ? feed.built     : nil,
        summary:      feed.summary?   ? feed.summary   : nil,
        title2:       feed.title2?    ? feed.title2    : nil,
        generator:    feed.generator
      }

      if debug?
        ## puts "*** dump feed_attribs:"
        ## pp feed_attribs
        puts "*** dump feed_attribs w/ class types:"
        feed_attribs.each do |key,value|
          puts "  #{key}: >#{value}< : #{value.class.name}"
        end
      end

      feed_rec.update_attributes!( feed_attribs )


      feed.items.each do |item|

        item_attribs = {
          fetched_at:   feed_fetched_at,
          title:        item.title,
          url:          item.url,
          summary:      item.summary?   ? item.summary   : nil,
          content:      item.content?   ? item.content   : nil,
          published_at: item.published? ? item.published : nil,
          touched_at:   item.updated?   ? item.updated   : nil,
          feed_id:      feed_rec.id    # add feed_id fk_ref
        }

        if debug?
          puts "*** dump item_attribs w/ class types:"
          item_attribs.each do |key,value|
            next if [:summary,:content].include?( key )   # skip summary n content
            puts "  #{key}: >#{value}< : #{value.class.name}"
          end
        end


        rec = Item.find_by_guid( item.guid )
        if rec.nil?
          rec      = Item.new
          item_attribs[ :guid ] = item.guid
          puts "** NEW | #{item.title}"
        else
          ## todo: check if any attribs changed
          puts "UPDATE | #{item.title}"
        end

        rec.update_attributes!( item_attribs )
      end  # each item

      #  update  cached value latest published_at for item
      item_recs = feed_rec.items.latest.limit(1).all
      unless item_recs.empty?
        if item_recs[0].published_at?
          feed_rec.latest_published_at = item_recs[0].published_at
        else # try touched_at
          feed_rec.latest_published_at = item_recs[0].touched_at
        end
        feed_rec.save!
      end

    end # each feed

  end # method update_feeds

 
end # class Refresher

end # module Pluto