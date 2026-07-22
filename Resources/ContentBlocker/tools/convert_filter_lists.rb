#!/usr/bin/env ruby
# frozen_string_literal: true
#
# One-off converter: Adblock Plus filter syntax (EasyList / EasyPrivacy) ->
# WKContentRuleList JSON (WebKit content-blocker schema).
#
# This script is NOT part of the shipped app. It is run once (and re-run
# whenever the bundled filter list is refreshed) to produce the static JSON
# resources under Resources/ContentBlocker/. Keeping conversion out of the
# app means no adblock-parsing code ships or runs on-device.
#
# Usage: ruby convert_filters.rb <easylist.txt> <easyprivacy.txt> <out_dir>

require "json"
require "set"

SEPARATOR = "[^a-zA-Z0-9_.%\\-]"

RESOURCE_TYPE_MAP = {
  "script" => "script",
  "image" => "image",
  "stylesheet" => "style-sheet",
  "font" => "font",
  "media" => "media",
  "popup" => "popup",
  "ping" => "ping",
  "websocket" => "websocket",
  "xmlhttprequest" => "fetch",
  "other" => "other",
  "document" => "document",
  "subdocument" => "document"
}.freeze

# Options that, if present, make the rule too complex/risky to convert
# faithfully (no WKContentRuleList equivalent) -> whole rule is dropped.
UNSUPPORTED_RULE_OPTIONS = %w[
  csp redirect redirect-rule rewrite removeparam empty mp4 replace
  cookie badfilter uritransform hls jsonprune inline-script inline-font
].freeze

# Options that are recognized but simply carry no effect in our converter
# (we keep the rule, just don't act on the option).
IGNORED_OPTIONS = %w[important matchcase doc popunder network extension].freeze

Stats = Hash.new(0)

def strip_bom(s)
  s.sub(/\A\xEF\xBB\xBF/, "")
end

def parse_domain_option(value)
  ifd = []
  unl = []
  value.split("|").each do |d|
    d = d.strip
    next if d.empty?
    if d.start_with?("~")
      unl << "*#{d[1..]}"
    else
      ifd << "*#{d}"
    end
  end
  [ifd, unl]
end

# WebKit's WKContentRuleList regex engine does not implement Perl-style
# shorthand character classes -- \d, \w, \s and their negations all fail
# compilation of the *entire* rule list with "Character class is not
# supported." (confirmed empirically; see convert_filter_lists.rb's git
# history / the ContentBlocker fix notes). They only show up in
# already-a-regex `/.../ ` filters copied verbatim from the source list, so
# expand them to the equivalent explicit character class, which WebKit does
# support.
SHORTHAND_CLASS_EXPANSIONS = {
  "d" => "0-9",
  "D" => "^0-9",
  "w" => "a-zA-Z0-9_",
  "W" => "^a-zA-Z0-9_",
  "s" => " \\t\\n\\r\\f\\v",
  "S" => "^ \\t\\n\\r\\f\\v"
}.freeze

# Expands \d \D \w \W \s \S into explicit character classes, and rejects
# (returns nil) patterns using \b -- WebKit also rejects word-boundary
# assertions ("Word boundaries assertions are not supported yet.") and
# there is no simple character-class equivalent for a zero-width assertion.
# Also rejects (returns nil) a shorthand class found *inside* an
# already-user-written `[...]` class: safely inlining a negated shorthand
# (e.g. \D) into an existing class without changing its meaning isn't
# generally possible, and this case doesn't occur in the bundled source
# lists, so it's simplest and safest to just drop those rules.
def expand_shorthand_classes(regex)
  out = +""
  in_class = false
  i = 0
  while i < regex.length
    c = regex[i]
    if c == "\\" && i + 1 < regex.length
      nxt = regex[i + 1]
      return nil if nxt == "b"
      if SHORTHAND_CLASS_EXPANSIONS.key?(nxt)
        return nil if in_class
        out << "[#{SHORTHAND_CLASS_EXPANSIONS[nxt]}]"
      else
        out << c << nxt
      end
      i += 2
      next
    end
    case c
    when "["
      in_class = true
    when "]"
      in_class = false
    end
    out << c
    i += 1
  end
  out
end

# Convert one Adblock Plus URL pattern (without options) into an ICU regex
# usable as a WKContentRuleList "url-filter".
def pattern_to_regex(pattern)
  return nil if pattern.empty?

  # Already-a-regex filters: /foo.*bar/
  if pattern.length > 1 && pattern.start_with?("/") && pattern.end_with?("/")
    inner = pattern[1..-2]
    # Reject constructs ICU/WebKit is unlikely to like or that are unsafe.
    return nil if inner.empty?
    return expand_shorthand_classes(inner)
  end

  s = pattern.dup
  prefix = ""
  suffix = ""

  if s.start_with?("||")
    prefix = "^[a-zA-Z-]+://([a-zA-Z0-9-]+\\.)?"
    s = s[2..]
  elsif s.start_with?("|")
    prefix = "^"
    s = s[1..]
  end

  if s.end_with?("|") && !s.end_with?("||")
    suffix = "$"
    s = s[0..-2]
  end

  out = +""
  i = 0
  while i < s.length
    c = s[i]
    case c
    when "*"
      out << ".*"
    when "^"
      # Adblock Plus semantics: "^" matches a single separator character OR
      # the end of the address. The natural regex for that is
      # `(?:SEPARATOR|$)`, but WebKit's WKContentRuleList regex engine does
      # not support disjunctions ("|") at all -- not even inside a
      # non-capturing group -- and rejects the *entire* compiled rule list
      # (WKErrorDomain code 6, "Disjunctions are not supported yet") if a
      # single rule's url-filter contains one. Since "^" is one of the most
      # common Adblock Plus constructs (used at the end of virtually every
      # `||domain.tld^` rule), this single construct alone was enough to
      # break compilation of ~90% of the bundled rules and take down ad
      # blocking entirely.
      #
      # Drop the end-of-address alternative and require an actual separator
      # character. This slightly under-matches bare origin requests with no
      # trailing character at all (e.g. a request for exactly
      # "https://example.com" with no path), which is rare in practice
      # since virtually all real requests carry a trailing "/" or other
      # separator; it is a far safer trade-off than a regex that matches
      # too little (dropping the whole group) or a rule that fails to
      # compile and disables blocking altogether.
      out << SEPARATOR
    when "|"
      # Stray separator mid-pattern; drop (rare, already handled at edges).
      nil
    else
      out << Regexp.escape(c)
    end
    i += 1
  end

  prefix + out + suffix
end

# WebKit's WKContentRuleList regex engine rejects any "|" disjunction
# outside a character class -- including inside a non-capturing group --
# and fails compilation of the *entire* rule list if even one rule's
# url-filter contains one (see the "^" case in pattern_to_regex above for
# the primary source of these; this is a safety net for the rest, chiefly
# already-a-regex `/.../` filters copied through verbatim, some of which
# use author-written alternations like `(club|xyz|top)`).
def contains_disjunction?(regex)
  in_class = false
  i = 0
  while i < regex.length
    c = regex[i]
    if c == "\\"
      i += 2
      next
    end
    case c
    when "["
      in_class = true
    when "]"
      in_class = false
    when "|"
      return true unless in_class
    end
    i += 1
  end
  false
end

# WebKit's WKContentRuleList regex engine also rejects `{n}` / `{n,}` /
# `{n,m}` brace-quantifiers outright -- on any atom (a literal char, a
# character class, a group, even `.`) -- with "Arbitrary atom repetitions
# are not supported." (confirmed empirically). This only shows up in
# already-a-regex `/.../ ` filters copied through verbatim (e.g.
# `[a-f0-9]{45,}`); the patterns this converter builds itself only ever use
# `*`, which WebKit does support. There is no general, safe way to rewrite
# an arbitrary `{n,}` (unbounded) into finite `*`/`+`/`?` repetition without
# a real regex parser identifying atom boundaries, so -- consistent with
# this converter's existing conservative stance on constructs it can't
# faithfully translate -- these rules are dropped rather than guessed at.
def contains_brace_quantifier?(regex)
  in_class = false
  i = 0
  while i < regex.length
    c = regex[i]
    if c == "\\"
      i += 2
      next
    end
    case c
    when "["
      in_class = true
    when "]"
      in_class = false
    when "{"
      return true if !in_class && regex[i..] =~ /\A\{\d*,?\d*\}/
    end
    i += 1
  end
  false
end

def convert_network_line(raw_line)
  line = raw_line
  is_exception = line.start_with?("@@")
  line = line[2..] if is_exception

  pattern_part, opts_part = line.split("$", 2)

  resource_types = []
  negated_type_seen = false
  load_types = []
  if_domain = []
  unless_domain = []
  case_sensitive = false
  drop_rule = false

  if opts_part
    opts_part.split(",").each do |opt|
      opt = opt.strip
      next if opt.empty?
      neg = opt.start_with?("~")
      key = neg ? opt[1..] : opt
      name, value = key.split("=", 2)

      if UNSUPPORTED_RULE_OPTIONS.include?(name)
        drop_rule = true
        next
      end

      case name
      when "third-party"
        load_types << (neg ? "first-party" : "third-party")
      when "domain"
        next unless value
        ifd, unl = parse_domain_option(value)
        if_domain.concat(ifd)
        unless_domain.concat(unl)
      when "matchcase"
        case_sensitive = true
      when *RESOURCE_TYPE_MAP.keys
        if neg
          negated_type_seen = true
        else
          resource_types << RESOURCE_TYPE_MAP[name]
        end
      when *IGNORED_OPTIONS
        # no-op, kept for readability of intent
        nil
      when "generichide", "elemhide", "genericblock", "specifichide"
        # Handled separately by the cosmetic pass; ignore here.
        nil
      else
        # Unknown option: be conservative and drop the whole rule rather
        # than risk over- or under-blocking on a misunderstood directive.
        drop_rule = true
      end
    end
  end

  return nil if drop_rule
  return nil if pattern_part.nil? || pattern_part.empty?

  regex = pattern_to_regex(pattern_part)
  return nil if regex.nil? || regex.empty?
  return nil if regex.bytesize > 2000 # WebKit rejects very long url-filters

  begin
    Regexp.new(regex)
  rescue RegexpError
    return nil
  end

  if contains_disjunction?(regex)
    Stats[:network_skipped_disjunction] += 1
    return nil
  end

  if contains_brace_quantifier?(regex)
    Stats[:network_skipped_brace_quantifier] += 1
    return nil
  end

  trigger = { "url-filter" => regex }
  trigger["url-filter-is-case-sensitive"] = true if case_sensitive
  trigger["resource-type"] = resource_types.uniq unless resource_types.empty?
  trigger["load-type"] = load_types.uniq unless load_types.empty?
  trigger["if-domain"] = if_domain.uniq unless if_domain.empty?
  trigger["unless-domain"] = unless_domain.uniq unless unless_domain.empty?

  {
    "trigger" => trigger,
    "action" => { "type" => is_exception ? "ignore-previous-rules" : "block" }
  }
end

SIMPLE_SELECTOR_RE = /\A[a-zA-Z0-9\s\.\#_\-\[\]="':,>~\*\^\$\(\)]+\z/

def selector_supported?(sel)
  return false if sel.empty? || sel.bytesize > 200
  return false if sel.include?(":has(") || sel.include?(":contains") ||
                  sel.include?(":-abp-") || sel.include?(":matches-css") ||
                  sel.include?(":xpath") || sel.include?(":upward") ||
                  sel.include?(":remove")
  !!(sel =~ SIMPLE_SELECTOR_RE)
end

def process_file(path, generic_selectors, domain_selectors, elemhide_exceptions)
  File.foreach(path, encoding: "UTF-8") do |raw|
    line = strip_bom(raw).strip
    Stats[:lines_total] += 1
    next if line.empty?
    if line.start_with?("!") || line.start_with?("[")
      Stats[:comments] += 1
      next
    end

    if line.include?("##") || line.include?("#@#") || line.include?("#?#") || line.include?("#$#")
      Stats[:cosmetic_total] += 1
      # Exception cosmetic rules and scriptlet/snippet rules are out of
      # scope for this converter.
      if line.include?("#@#") || line.include?("#$#") || line.include?("#?#")
        Stats[:cosmetic_skipped_unsupported] += 1
        next
      end

      domains_part, sel = line.split("##", 2)
      next if sel.nil?
      unless selector_supported?(sel)
        Stats[:cosmetic_skipped_selector] += 1
        next
      end

      if domains_part.nil? || domains_part.empty?
        generic_selectors << sel
        Stats[:cosmetic_generic] += 1
      else
        domains_part.split(",").each do |d|
          d = d.strip
          next if d.empty?
          if d.start_with?("~")
            elemhide_exceptions << d[1..]
          else
            (domain_selectors[d] ||= []) << sel
          end
        end
        Stats[:cosmetic_domain] += 1
      end
      next
    end

    # Options-only lines like "example.com#$#..." already handled above;
    # anything left is a network filter (or exception).
    Stats[:network_total] += 1
    rule = convert_network_line(line)
    if rule
      Stats[:network_converted] += 1
      yield rule
    else
      Stats[:network_skipped] += 1
    end
  end
end

def chunk_selectors(selectors, max_chars: 6000)
  chunks = []
  current = []
  size = 0
  selectors.each do |sel|
    if size + sel.length + 1 > max_chars && !current.empty?
      chunks << current
      current = []
      size = 0
    end
    current << sel
    size += sel.length + 1
  end
  chunks << current unless current.empty?
  chunks
end

easylist_path, easyprivacy_path, out_dir = ARGV
abort "usage: convert_filters.rb easylist.txt easyprivacy.txt out_dir" unless out_dir

Dir.mkdir(out_dir) unless Dir.exist?(out_dir)

ads_rules = []
tracker_rules = []
generic_selectors = Set.new
domain_selectors = {}
elemhide_exceptions = Set.new

process_file(easylist_path, generic_selectors, domain_selectors, elemhide_exceptions) { |r| ads_rules << r }
process_file(easyprivacy_path, generic_selectors, domain_selectors, elemhide_exceptions) { |r| tracker_rules << r }

# Dedupe network rules (both lists share many mirrored rules).
def dedupe(rules)
  seen = Set.new
  rules.select do |r|
    key = r.to_s
    if seen.include?(key)
      false
    else
      seen << key
      true
    end
  end
end

ads_rules = dedupe(ads_rules)
tracker_rules = dedupe(tracker_rules)

# --- cosmetic-lite: generic (site-agnostic) element hiding, batched into a
# small number of rules each with a combined CSS selector list, plus a
# handful of domain-scoped exceptions for sites that opt out of generic
# hiding (EasyList's `$generichide`/`#@#` domains).
cosmetic_rules = []
sorted_generic = generic_selectors.to_a.sort.first(20_000)
chunk_selectors(sorted_generic).each do |chunk|
  trigger = { "url-filter" => ".*" }
  unless elemhide_exceptions.empty?
    trigger["unless-domain"] = elemhide_exceptions.to_a.sort.first(2_000).map { |d| "*#{d}" }
  end
  cosmetic_rules << {
    "trigger" => trigger,
    "action" => { "type" => "css-display-none", "selector" => chunk.join(", ") }
  }
end
Stats[:cosmetic_rules_emitted] = cosmetic_rules.length
Stats[:cosmetic_generic_selectors_kept] = sorted_generic.length
Stats[:cosmetic_domain_selectors_dropped] = domain_selectors.values.map(&:length).sum

File.write(File.join(out_dir, "ads.json"), JSON.generate(ads_rules))
File.write(File.join(out_dir, "trackers.json"), JSON.generate(tracker_rules))
File.write(File.join(out_dir, "cosmetic-lite.json"), JSON.generate(cosmetic_rules))

def header_field(path, name)
  File.foreach(path).first(10).each do |l|
    m = l.match(/^!\s*#{name}:\s*(.+)$/)
    return m[1].strip if m
  end
  nil
end

manifest = {
  "version" => header_field(easylist_path, "Version") || Time.now.utc.strftime("%Y%m%d%H%M"),
  "generatedAt" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
  "sources" => [
    {
      "name" => "EasyList",
      "url" => "https://easylist.to/easylist/easylist.txt",
      "listVersion" => header_field(easylist_path, "Version"),
      "lastModified" => header_field(easylist_path, "Last modified"),
      "commit" => header_field(easylist_path, "Commit")
    },
    {
      "name" => "EasyPrivacy",
      "url" => "https://easylist.to/easylist/easyprivacy.txt",
      "listVersion" => header_field(easyprivacy_path, "Version"),
      "lastModified" => header_field(easyprivacy_path, "Last modified"),
      "commit" => header_field(easyprivacy_path, "Commit")
    }
  ],
  "license" => "GPLv3 OR CC-BY-SA-3.0 (EasyList authors, https://easylist.to/)",
  "files" => {
    "ads.json" => { "rules" => ads_rules.length },
    "trackers.json" => { "rules" => tracker_rules.length },
    "cosmetic-lite.json" => { "rules" => cosmetic_rules.length, "selectors" => sorted_generic.length }
  },
  "totalRulesWithCosmetic" => ads_rules.length + tracker_rules.length + cosmetic_rules.length,
  "totalRulesWithoutCosmetic" => ads_rules.length + tracker_rules.length,
  "maxRulesPerCompiledList" => 150_000,
  "conversionStats" => Stats.sort.to_h
}
File.write(File.join(out_dir, "manifest.json"), JSON.pretty_generate(manifest))

puts "ads.json: #{ads_rules.length} rules"
puts "trackers.json: #{tracker_rules.length} rules"
puts "cosmetic-lite.json: #{cosmetic_rules.length} rules (#{sorted_generic.length} selectors)"
puts "---"
Stats.sort.each { |k, v| puts "#{k}: #{v}" }
