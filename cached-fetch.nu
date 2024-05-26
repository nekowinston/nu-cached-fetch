# SPDX-FileCopyrightText: 2024 winston <hey@winston.sh>
# SPDX-License-Identifier: MIT

let cacheDir = ($env.XDG_CACHE_HOME | default $"($env.HOME)/.cache") | path join "nu/http-cache"
let cacheDb = $cacheDir | path join "cache.sqlite"

# TODO:
# these are currently blocked by https://github.com/nushell/nushell/issues/9116
# --password (-p): string      # the password when authenticating
# --max-time (-m): string      # timeout period in seconds
# --insecure (-k)              # allow insecure server connections when using SSL

export def cached-fetch [
  url: string                  # The URL to fetch the contents from.
  --ttl (-t): duration = 7day  # The duration to cache the contents for.
  --headers (-H): any          # custom headers you want to add
  --raw (-r)                   # fetch contents as text rather than a table
  --full (-f)                  # returns the full response instead of only the body
  --redirect-mode (-R): string # What to do when encountering redirects. Default: 'follow'. Valid options: 'follow' ('f'), 'manual' ('m'), 'error' ('e').
] -> any {
  mkdir $cacheDir

  let cacheName = $url | hash sha256
  let cachePath = $cacheDir | path join $cacheName

  if not (
    ($cachePath | path exists) and
    (ls $cachePath | where modified > ((date now) - $ttl) | is-not-empty)
  ) {
    let response = http get --raw --full $url --headers ($headers | default []) --redirect-mode=($redirect_mode | default "follow")
    let headers = $response.headers.response | reduce -f {} {|it, acc| $acc | upsert $it.name $it.value }

    let contentType = $headers
      | get content-type?
      | default "application/octet-stream"
      | parse --regex `([^;\n]*)`
      | get capture0
      | first
    let fileName = $headers
      | get content-disposition?
      | default $"filename=($url | url parse | get path | path basename)"
      | parse --regex `filename[^;=\n]*=((['\"]).*?\2|[^;\n]*)`
      | get capture0
      | first

    { shasum: $cacheName
      status: $response.status
      contentType: $contentType
      fileName: $fileName
    } | into sqlite $cacheDb

    $response | get body | save $cachePath
  }

  cached-open $cacheName $raw $full
}

def cached-open [path: string, raw: bool, full: bool] -> any {
  let data = open --raw ($cacheDir | path join $path)
  let metadata = (open $cacheDb).main | where "shasum" == $path | first

  let parsed = if not ($raw or $metadata.contentType == "application/octet-stream") {
    if (($metadata.contentType =~ `\+json$`) or ($metadata.fileName =~ `\.json[5c]?$`)) {
      $data | from json
    } else if ($metadata.fileName =~ `\.ya?ml$`) {
      $data | from yaml
    } else if (($metadata.contentType =~ `\+xml$`) or ($metadata.fileName =~ `\.xml$`)) {
      $data | from xml
    } else {
      match $metadata.contentType {
        "application/json" => ($data | from json)
        "application/msgpack" => ($data | from msgpack)
        "application/toml" => ($data | from toml)
        "application/vnd.oasis.opendocument.spreadsheet" => ($data | from ods)
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => ($data | from xlsx)
        "application/xml" | "text/xml" => ($data | from xml)
        "text/csv" => ($data | from csv)
        "text/tab-separated-values" => ($data | from tsv)
        "text/yaml" => ($data | from yaml)
        _ =>  ($data | from guess)
      }
    } | into record
  } else { 
    $data
  }

  if $full {
    {
      headers: {
        response: {
          "content-type": $metadata.contentType,
          "content-disposition": $"filename=($metadata.fileName)"
        }
      },
      body: $parsed,
      status: $metadata.status,
    }
  } else {
    $parsed
  }
}

# stupidly try to parse all supported formats
def "from guess" [] -> any {
  let data = $in

  $data | try { from json } catch {
    $data | try { from yaml } catch {
      $data | try { from toml } catch {
        $data | try { from xml } catch {
          $data | try { from msgpack } catch {
            $data | try { from msgpackz } catch {
              $data | try { from csv } catch {
                $data | try { from tsv } catch {
                  $data | try { from ssv } catch {
                    $data | try { from xlsx } catch {
                      $data | try { from ods }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
