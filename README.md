# cached fetch for nu
Nu function that downloads & caches files for a given TTL in\
`($env.XDG_CACHE_HOME | default $"($env.HOME)/.cache") | path join "nu/http-cache"`.
