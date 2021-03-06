#!/usr/bin/env ruby

require_relative 'accidentalculture/search'
require_relative 'accidentalculture/clean'
require_relative 'accidentalculture/download'
require_relative 'accidentalculture/word'
require_relative 'accidentalculture/twitter'
require_relative 'accidentalculture/dotgif'
require_relative 'accidentalculture/store'
require ENV["HOME"]+'/accidentalculture/etc/conf/api_keys'
require ENV["HOME"]+'/accidentalculture/etc/conf/mongo_conf'
require 'timeout'


if __FILE__ == $0

	$video_dir = ENV["HOME"]+'/accidentalculture/tmp_v/*'

	def shut_it_down
		#delete tmp_v
		FileUtils.rm_rf(Dir.glob($video_dir))
		exit
	end

	def get_results
		if ARGV.empty?
			$searchterm = Word::get_word
		else
			$searchterm = ARGV[0]
		end

		puts "search term is #{$searchterm}"
		itemlimit = 100
		#set up for api, search
		__APIS__ = {:dpla=>"http://api.dp.la/v2/%s?api_key=#{API_KEYS[:dpla]}&%s"}
		c = Search::Client.new(__APIS__[:dpla])
		video_results = Clean::clean_results c.search($searchterm, '"moving image"', 'items', itemlimit)
		#here, video should be a list of potential sources with their relevant metadata
		#so depending on which document.dl_info.type it has, go get the video
		if video_results.nil?
			puts "Sorry, after much consideration of your request, there are no viable downloads for #{$searchterm}"
			get_results
		else
			puts "Starting to download..."			
			dl_result = video_results.length > 6 ? video_results.shuffle.take(6).each{|v| Download::download_videos v} : video_results.each{|v| Download::download_videos v}
			
			if dl_result.length == 0
				get_results
			end
		end
	end

	begin
		Timeout.timeout(480) do
			while Dir[$video_dir].empty?
				get_results
			end

			#trigger gif
			gif_res = DotGif::search_and_deploy

			#with info returned from gif, pass to twitter
			if gif_res.class == Hash
				title = gif_res[:record]['source_resource']['title']

				if title.class == Array
					title = title[0]
				end

				#lets mark as sensitive media if nudity, unfortunately
				sensitive = title.downcase.include?("nude") ? true : false

				title = title.split[0...5].join(' ')
				title << "..."
				respath = gif_res[:_id].split('_')[0]
				link = "http://dp.la/item/" << respath
				if !$searchterm.nil?
					text = "Searched: #{$searchterm}. Got: #{title} from #{link}"
				else
					text = "#{title} from #{link}"
				end

				post = Twitter::post_content(text, gif_res[:gif], sensitive)
				#add information brought back from twitter to the record we are saving
				gif_res[:twitter_post_id] = post.id
				#add the search term, too
				gif_res[:search_term] = $searchterm
				#save this to mongo
				begin
					storage = Store::MongoStore.new(MONGO_CONF[:host], MONGO_CONF[:port], MONGO_CONF[:database], MONGO_CONF[:collection])
					storage.insertdoc(gif_res)
				rescue => error
					puts "Something wrong happened when storing, and it was: #{error}"
				end
			else
				puts "No, I'm done, it didn't work, there's nothing to post, I'm sorry, Just try again later, I'm through *ugh*."
				shut_it_down
			end
			#when all done, clear out everything in tmp_v
			shut_it_down
		end
	rescue Timeout::Error
		puts "For whatever reason, this is taking too long and we're just going to quit"
		shut_it_down
	end
	
end
