# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Ruby libs
require 'ftools'

module Cache
  private

  # Get the size of a directory (including sub-dirs)
  # Arguments
  # * dir: dirname
  # * output: OutputControl instance
  # Output
  # * returns the size in bytes if the directory exist, 0 otherwise
  def Cache::get_dir_size(dir, output)
    sum = 0
    if FileTest.directory?(dir) then
      begin
        Dir.foreach(dir) { |f|
          if (f != ".") && (f != "..") then
            if FileTest.directory?(dir + "/" + f) then
              sum += get_dir_size(dir + "/" + f, output)
            else
              sum += File.stat(dir + "/" + f).size
            end
          end
        }
      rescue
        output.debug_server("Access not allowed in the cache: #{$!}")
      end
    end
    return sum
  end

  public

  # Clean a cache according an LRU policy
  #
  # Arguments
  # * dir: cache directory
  # * max_size: maximum size for the cache in Bytes
  # * time_before_delete: time in hours before a file can be deleted
  # * pattern: pattern of the files that might be deleted
  # * output: OutputControl instance
  # Output
  # * nothing
  def Cache::clean_cache(dir, max_size, time_before_delete, pattern, output)
    no_change = false
    while (get_dir_size(dir, output) > max_size) && (not no_change)
      lru = ""
      begin
        Dir.foreach(dir) { |f|
          if ((f =~ pattern) == 0) && (f != "..") && (f != ".") then
            access_time = File.atime(dir + "/" + f).to_i
            now = Time.now.to_i
            #We only delete the file older than a given number of hours
            if  ((now - access_time) > (60 * 60 * time_before_delete)) && ((lru == "") || (File.atime(lru).to_i > access_time)) then
              lru = dir + "/" + f
            end
          end
        }
        if (lru != "") then
          begin
            File.delete(lru)
          rescue
            output.debug_server("Cannot delete the file #{dir}/#{f}: #{$!}")
          end
        else
          no_change = true
        end
      rescue
        output.debug_server("Access not allowed in the cache: #{$!}")
      end
    end
  end
  
  # Remove some files in a cache
  #
  # Arguments
  # * dir: cache directory
  # * pattern: pattern of the files that must be deleted
  # * output: OutputControl instance
  # Output
  # * nothing
  def Cache::remove_files(dir, pattern, output)
    Dir.foreach(dir) { |f|
      if ((f =~ pattern) == 0) && (f != "..") && (f != ".") then
        begin
          File.delete("#{dir}/#{f}")
        rescue
          output.debug_server("Cannot delete the file #{dir}/#{f}: #{$!}")
        end
      end
    }
  end
end
