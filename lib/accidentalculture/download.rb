#!/usr/bin/env ruby

###
#download what we have returned from search and cleaned
###

require 'nokogiri'
require 'capybara/poltergeist'	
require 'phantomjs'
require 'timeout'
require 'open-uri'
require 'open_uri_redirections'
require 'json'
require 'youtube-dl.rb'


module Download
	def self.checkHeaders(u)		
		uri = URI.parse(u)
		http = Net::HTTP.new(uri.host, uri.port)
		req = Net::HTTP::Get.new(uri.request_uri)
		res = http.request(req)
		ct = res.content_type	
		b = res.body

		#this check could be infinitely better.
		#might not even use this if we don't pull from
		#cdm providers that provide a shortcut .url file
		#instead of a video file.
		status = Hash.new
		if ct.include?('video')
			status[:ok] = true
			status[:with] = nil
		elsif ct.include?('application')
			status[:ok] = false
			status[:with] = b
		end
		return status	
	end

	def self.checkWhichUrl(us)
		ans = Array.new
		us.each { |u|
			begin
				res = open(u, :allow_redirections => :all)
			rescue OpenURI::HTTPError
				status = nil
			else
				status = res.status[0]
			end
			if status == '200'
				ans.push(u)
			end
		}
		return ans[0]
	end

	def self.download(url, someid, v)
		path = ENV["HOME"]+"/accidentalculture/tmp_v/#{someid}"
		#save download url to json
		v[:dl_url] = url
		#also save metadata for file, so we can retrieve later
		md = path+".json"
		open(md, 'wb') do |m|
			m.write(v.to_json)
		end
		#use timeout to cut of extra long downloads (over 30 sec is too much)
		begin
			timeout(60) do
				if url.include?('youtube.com')
					begin
						options = {output: path, format: :worst}	
						YoutubeDL.download url, options
					rescue => error
						puts "Error downloading youtube video #{error}"
						# figure out what's going on with the path
						File.delete(path)
						File.delete(md)
					end
				else
					open(path, 'wb') do |f|
						puts "DOWNLOADING: #{url}"
						begin
							dl = open(url, :allow_redirections => :all)
						rescue OpenURI::HTTPError => ex
			  				puts "Oops #{ex}"
			  				File.delete(path)
			  				File.delete(md)
						end
			  			
			  			f << dl.read
			  		end
			  	end
			end
		rescue Timeout::Error
			puts "#{url} is taking too long, probably way too large for our needs"
			File.delete(path)
			File.delete(md)
		end
	end

	#only one of these will get used for a v
	#each one should return a url that is the direct resource location
	def self.getUrl(v, file_id)
		#this is pretty tied to `http://dp.la/api/contributor/georgia` right now,
		#but there are no other providers with this requirement currently in our
		#list of targets
		start_url = v[:original_url]
		resid = start_url.split(':')[-1]
		if start_url.include? "id:"
			url = v[:dl_info][:f4vpath] % resid
		elsif start_url.include? "do-mp4:"
			url = v[:dl_info][:mp4path] % resid
		else
			url = nil
		end
		
		if !url.nil?
			download url, file_id, v
		else
			puts "no pattern for URL: #{start_url}"
		end
	end

	def self.getCDL(v, file_id)
		cdl_url = v[:original_url]
		if cdl_url.include?("youtube.com")
			download cdl_url, file_id, v
		else
			archive_id = cdl_url.split('/').last
			dl_url = "https://archive.org/download/#{archive_id}/#{archive_id}_access.mp4"
			hd_dl_url = "https://archive.org/download/#{archive_id}/#{archive_id}_access.HD.mp4"
			archive_url = checkWhichUrl [dl_url, hd_dl_url]
			if !archive_url.nil?
				download archive_url, file_id, v
			else
				puts "tried to download this archive.org resource for #{file_id}, but could not find a useful url"
			end
		end
	end


	def self.handleUrlShortcut(sc)
		#sometimes you are given back a url shortcut text file, parse this to see if blank or has location
		f = sc.lines
		url = f.find {|e| /URL/ =~ e}.split('=')[1].strip
	end

	def self.getCDM(v, file_id)
		#need to check if there is actually a video downloaded or a url shortcut file (and parse the latter)
		ourl = v[:original_url].sub('cdm/ref', 'utils/getstream')
		proceed = checkHeaders ourl
		url = proceed[:ok] == false ? handleUrlShortcut(proceed[:with]) : ourl

		if url != 'about:blank' && !url.nil?
			download url, file_id, v
		else
			puts "forget it, we won't be able to download from #{ourl}...moving on."
		end
	end

	def self.getSrc(v, file_id) 
		url = v[:original_url]
		puts "TRYING TO GET srcUrl for #{url}"
		browser_options = {:js_errors => false, :timeout => 120, :phantomjs => Phantomjs.path}
		Capybara.register_driver :poltergeist do |app|
			Capybara::Poltergeist::Driver.new(app, browser_options)
		end
		session = Capybara::Session.new(:poltergeist)
		#TODO - wrap this in begin, since it might fail
		session.visit url
		page = Nokogiri::HTML(session.html) #allowing all redirs is risky, but since we know where we are getting stuff from, it's okay for now.
		srcUrl = page.css(v[:dl_info][:path]).first[v[:dl_info][:sel]]
		if !srcUrl.nil?
			download srcUrl, file_id, v
		else
			puts "url is empty for #{v[:dpla_id]}, probably because attempt to get resource was botched. skipping."
		end
	end

	def self.download_videos(v)
		f = v[:dl_info][:type]
		fid = v[:dpla_id]
		begin
			send(f, v, fid)
		rescue => error
			puts "Something went wrong with the download, and it was: #{error}"
		end
	end
end
