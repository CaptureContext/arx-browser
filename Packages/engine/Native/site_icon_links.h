#ifndef ARX_SITE_ICON_LINKS_H_
#define ARX_SITE_ICON_LINKS_H_

// Standard-library only, so the policy runs under sanitizers without Chromium.
// It reads the icons a page declares in its <head> for a page that has never
// loaded in the profile. No script runs and nothing is rendered: the scan only
// looks at <base> and <link> start tags until the head ends.

#include <algorithm>
#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace arx::site_icons {

inline constexpr size_t kMaximumHeadBytes = 512 * 1024;
inline constexpr size_t kMaximumCandidates = 3;
inline constexpr size_t kMaximumHrefBytes = 2048;
inline constexpr int kPreferredPixels = 32;

struct IconLink {
  std::string href;
  // Largest declared edge; 0 when unknown, -1 for sizes="any" (vector icons).
  int size = 0;
  bool touch = false;
};

struct IconLinks {
  std::optional<std::string> base;
  std::vector<IconLink> icons;
  // True once </head> or <body> showed up: more bytes cannot add icons.
  bool complete = false;
};

namespace internal {
inline char Lower(char c) {
  return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
}

inline bool Space(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

inline std::string LowerCopy(std::string_view text) {
  std::string result(text);
  std::transform(result.begin(), result.end(), result.begin(), Lower);
  return result;
}

inline bool StartsWithTag(std::string_view text, size_t at, std::string_view tag) {
  if (at > text.size() || text.size() - at < tag.size()) return false;
  for (size_t i = 0; i < tag.size(); ++i)
    if (Lower(text[at + i]) != tag[i]) return false;
  const size_t end = at + tag.size();
  return end == text.size() || Space(text[end]) || text[end] == '>' || text[end] == '/';
}

inline std::string_view Trim(std::string_view text) {
  while (!text.empty() && Space(text.front())) text.remove_prefix(1);
  while (!text.empty() && Space(text.back())) text.remove_suffix(1);
  return text;
}

inline bool HasToken(std::string_view list, std::string_view token) {
  size_t at = 0;
  while (at < list.size()) {
    while (at < list.size() && Space(list[at])) ++at;
    size_t end = at;
    while (end < list.size() && !Space(list[end])) ++end;
    if (list.substr(at, end - at) == token) return true;
    at = end;
  }
  return false;
}

// Largest WxH in a sizes list; -1 for "any", 0 when nothing parses.
inline int LargestSize(std::string_view sizes) {
  int largest = 0;
  size_t at = 0;
  while (at < sizes.size()) {
    while (at < sizes.size() && Space(sizes[at])) ++at;
    size_t end = at;
    while (end < sizes.size() && !Space(sizes[end])) ++end;
    const std::string_view token = sizes.substr(at, end - at);
    at = end;
    if (token == "any") return -1;
    const size_t x = token.find('x');
    if (x == 0 || x == std::string_view::npos || x + 1 == token.size()) continue;
    int edge = 0;
    bool valid = true;
    for (const std::string_view part : {token.substr(0, x), token.substr(x + 1)}) {
      if (part.size() > 5) { valid = false; break; }
      int value = 0;
      for (char c : part) {
        if (c < '0' || c > '9') { valid = false; break; }
        value = value * 10 + (c - '0');
      }
      if (!valid || value == 0) { valid = false; break; }
      edge = std::max(edge, value);
    }
    if (valid) largest = std::max(largest, edge);
  }
  return largest;
}

// Decodes the few character references that appear in icon URLs. Anything
// else stays as written; URL resolution rejects what does not parse.
inline std::string DecodeReferences(std::string_view text) {
  std::string result;
  result.reserve(text.size());
  for (size_t i = 0; i < text.size(); ++i) {
    if (text[i] == '&') {
      const std::string_view rest = text.substr(i);
      if (rest.starts_with("&amp;")) { result += '&'; i += 4; continue; }
      if (rest.starts_with("&#38;")) { result += '&'; i += 4; continue; }
      if (rest.starts_with("&quot;")) { result += '"'; i += 5; continue; }
      if (rest.starts_with("&#39;")) { result += '\''; i += 4; continue; }
    }
    result += text[i];
  }
  return result;
}

struct Attribute {
  std::string name;
  std::string_view value;
};

// Reads attributes of a start tag beginning at `at` (just after its name).
// Returns the offset after '>' or npos when the tag is cut off.
inline size_t ReadAttributes(std::string_view text, size_t at, std::vector<Attribute>& out) {
  while (at < text.size()) {
    while (at < text.size() && (Space(text[at]) || text[at] == '/')) ++at;
    if (at >= text.size()) return std::string_view::npos;
    if (text[at] == '>') return at + 1;
    size_t name_end = at;
    while (name_end < text.size() && !Space(text[name_end]) && text[name_end] != '=' &&
           text[name_end] != '>' && text[name_end] != '/')
      ++name_end;
    Attribute attribute{LowerCopy(text.substr(at, name_end - at)), {}};
    at = name_end;
    while (at < text.size() && Space(text[at])) ++at;
    if (at < text.size() && text[at] == '=') {
      ++at;
      while (at < text.size() && Space(text[at])) ++at;
      if (at >= text.size()) return std::string_view::npos;
      if (text[at] == '"' || text[at] == '\'') {
        const char quote = text[at++];
        const size_t close = text.find(quote, at);
        if (close == std::string_view::npos) return std::string_view::npos;
        attribute.value = text.substr(at, close - at);
        at = close + 1;
      } else {
        size_t end = at;
        while (end < text.size() && !Space(text[end]) && text[end] != '>') ++end;
        attribute.value = text.substr(at, end - at);
        at = end;
      }
    }
    if (out.size() < 32) out.push_back(std::move(attribute));
  }
  return std::string_view::npos;
}

inline std::string_view Value(const std::vector<Attribute>& attributes, std::string_view name) {
  for (const auto& attribute : attributes)
    if (attribute.name == name) return attribute.value;
  return {};
}

inline bool Vector(std::string_view href, std::string_view type) {
  const std::string lowered = LowerCopy(Trim(type));
  if (lowered == "image/svg+xml") return true;
  std::string path = LowerCopy(href.substr(0, href.find_first_of("?#")));
  return path.ends_with(".svg") || LowerCopy(href).starts_with("data:image/svg");
}

// Lower is better. Prefers a declared 32px raster icon, then any other icon,
// then Apple's touch icon, which is large but always raster.
inline int Score(const IconLink& icon) {
  int score = icon.touch ? 1000 : 0;
  if (icon.size == 0) return score + 100;
  if (icon.size >= kPreferredPixels) return score + (icon.size - kPreferredPixels);
  return score + 50 + (kPreferredPixels - icon.size) * 4;
}
}  // namespace internal

// Scans at most kMaximumHeadBytes of a page for <base href> and icon links.
// Comments, scripts and styles are skipped whole; a tag cut off at the end of
// the input is ignored. Vector and mask icons are dropped: the profile
// database stores raster bitmaps and the decoder does not render SVG.
inline IconLinks ParseIconLinks(std::string_view html) {
  using namespace internal;
  IconLinks result;
  html = html.substr(0, std::min(html.size(), kMaximumHeadBytes));
  size_t at = 0;
  while ((at = html.find('<', at)) != std::string_view::npos) {
    const std::string_view rest = html.substr(at);
    if (rest.starts_with("<!--")) {
      const size_t end = html.find("-->", at + 4);
      if (end == std::string_view::npos) break;
      at = end + 3;
      continue;
    }
    bool skipped = false;
    for (std::string_view raw : {std::string_view("script"), std::string_view("style"),
                                 std::string_view("noscript"), std::string_view("template")}) {
      if (!StartsWithTag(html, at + 1, raw)) continue;
      const std::string closing = "</" + std::string(raw);
      size_t search = at + 1 + raw.size();
      size_t found = std::string_view::npos;
      while (search < html.size()) {
        const size_t candidate = html.find("</", search);
        if (candidate == std::string_view::npos) break;
        if (StartsWithTag(html, candidate + 2, raw)) { found = candidate; break; }
        search = candidate + 2;
      }
      at = found == std::string_view::npos ? html.size() : found + closing.size();
      skipped = true;
      break;
    }
    if (skipped) continue;
    if (StartsWithTag(html, at + 1, "body") ||
        (at + 1 < html.size() && html[at + 1] == '/' && StartsWithTag(html, at + 2, "head"))) {
      result.complete = true;
      break;
    }
    const bool link = StartsWithTag(html, at + 1, "link");
    const bool base = !link && StartsWithTag(html, at + 1, "base");
    if (!link && !base) {
      ++at;
      continue;
    }
    std::vector<Attribute> attributes;
    const size_t end = ReadAttributes(html, at + 5, attributes);
    if (end == std::string_view::npos) break;
    at = end;
    const std::string_view href = Trim(Value(attributes, "href"));
    if (href.empty() || href.size() > kMaximumHrefBytes) continue;
    if (base) {
      if (!result.base) result.base = DecodeReferences(href);
      continue;
    }
    const std::string rel = LowerCopy(Value(attributes, "rel"));
    const bool touch = HasToken(rel, "apple-touch-icon") ||
                       HasToken(rel, "apple-touch-icon-precomposed");
    if (!touch && !HasToken(rel, "icon")) continue;
    if (Vector(href, Value(attributes, "type"))) continue;
    const int size = LargestSize(LowerCopy(Value(attributes, "sizes")));
    if (size < 0) continue;
    if (result.icons.size() < 32)
      result.icons.push_back({DecodeReferences(href), size, touch});
  }
  return result;
}

// The best few declared icons, in the order they should be tried.
inline std::vector<IconLink> RankIconLinks(std::vector<IconLink> icons) {
  std::stable_sort(icons.begin(), icons.end(), [](const IconLink& a, const IconLink& b) {
    return internal::Score(a) < internal::Score(b);
  });
  std::vector<IconLink> result;
  for (auto& icon : icons) {
    if (result.size() == kMaximumCandidates) break;
    if (std::any_of(result.begin(), result.end(),
                    [&](const IconLink& kept) { return kept.href == icon.href; }))
      continue;
    result.push_back(std::move(icon));
  }
  return result;
}

// Whether a root page that ended on `final_host` speaks for the site on
// `requested_host`: the same host, with or without a leading "www.". A page on
// another host, such as a sign-in page or another app of the same company,
// declares that host's icons, never the requested site's (DEV-1108).
inline bool SpeaksForHost(std::string_view requested_host, std::string_view final_host) {
  const auto bare = [](std::string_view host) {
    std::string result = internal::LowerCopy(host);
    if (!result.empty() && result.back() == '.') result.pop_back();
    if (result.starts_with("www.")) result.erase(0, 4);
    return result;
  };
  const std::string requested = bare(requested_host);
  return !requested.empty() && requested == bare(final_host);
}

// The directory of a saved page's first path segment ("/spreadsheets/d/x/edit"
// gives "/spreadsheets/"), whose page declares the app's own icon on a host with
// several apps: Docs and Sheets, Outlook's mail and calendar (DEV-1108). Only
// when the saved path goes on past that segment, and the segment is a plain
// name: never the saved page itself, more of its path, its query or fragment,
// since a saved URL may be a one-time link. Empty otherwise.
inline std::string AppDirectory(std::string_view path) {
  if (path.size() < 2 || path.front() != '/') return std::string();
  const size_t end = path.find('/', 1);
  if (end == std::string_view::npos || end + 1 >= path.size()) return std::string();
  const std::string_view segment = path.substr(1, end - 1);
  if (segment.empty() || segment.size() > 32) return std::string();
  bool letter = false;
  for (const char c : segment) {
    const char lowered = internal::Lower(c);
    if (lowered >= 'a' && lowered <= 'z') {
      letter = true;
    } else if (!(c >= '0' && c <= '9') && c != '-' && c != '_' && c != '.') {
      return std::string();
    }
  }
  if (!letter) return std::string();
  return "/" + std::string(segment) + "/";
}

// Scales an icon edge pair to fit a square of `limit` pixels, never upward.
inline std::pair<int, int> FitIcon(int width, int height, int limit) {
  if (width <= 0 || height <= 0) return {0, 0};
  if (width <= limit && height <= limit) return {width, height};
  const long long longest = std::max(width, height);
  const int fitted_width = static_cast<int>(std::max<long long>(1, (width * 1LL * limit + longest / 2) / longest));
  const int fitted_height = static_cast<int>(std::max<long long>(1, (height * 1LL * limit + longest / 2) / longest));
  return {fitted_width, fitted_height};
}
}  // namespace arx::site_icons

#endif  // ARX_SITE_ICON_LINKS_H_
