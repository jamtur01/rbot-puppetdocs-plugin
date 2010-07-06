# Puppet Docs URL plug-in

## Requires the following gems:

* mechanize
* nokogiri

## Configuration options (to be placed in conf.yaml)

puppetdocs_urls.channelmap - A map of channels to the base Redmine URL that should be used in that channel.  Format for each entry in the list #channel:http://puppetdocs.site/to/use.  Don't put a trailing slash on the base URL, please.

conf.yaml:

puppetdocs_urls.channelmap:
- "#channel:http://url/to"
