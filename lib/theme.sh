#!/usr/bin/env bash
# Shared Avagato Guacamole theme builder.

AVAGATO_THEME_VERSION="1.0.0"

theme_manifest(){
  unzip -p "$1" guac-manifest.json 2>/dev/null || true
}

theme_jar_version(){
  local manifest
  manifest="$(theme_manifest "$1")"
  sed -n 's/.*"avagatoThemeVersion":"\([^"]*\)".*/\1/p' <<<"$manifest"
}

theme_jar_is_ours(){
  local jar_path="$1" manifest
  [[ -f "$jar_path" ]] || return 1
  manifest="$(theme_manifest "$jar_path")"
  [[ "$manifest" == *'"guacamoleVersion":"1.6.0"'* ]] &&
  { [[ "$manifest" == *'"name":"Avagato Theme"'* ]] || [[ "$manifest" == *'"name":"Avagato Dark Theme"'* ]]; } &&
  { [[ "$manifest" == *'"namespace":"avagato-dark-theme"'* ]] || [[ "$manifest" == *'"namespace":"dark-theme"'* ]]; }
}

build_theme()(
  local out="$1" work asset_base
  work="$(mktemp -d)"
  trap 'rm -rf "${work:-}"' EXIT
  asset_base="${AVAGATO_ASSET_BASE:-https://raw.githubusercontent.com/samwathegreat/avagato/main/theme/assets}"
  install -d "$work/resources/images" "$work/translations"

  curl -fL --retry 3 --proto '=https' --tlsv1.2 "$asset_base/avagato-login.png" -o "$work/resources/images/avagato-login.png"
  curl -fL --retry 3 --proto '=https' --tlsv1.2 "$asset_base/avagato-large.png" -o "$work/resources/images/avagato-large.png"
  curl -fL --retry 3 --proto '=https' --tlsv1.2 "$asset_base/avagato-small.png" -o "$work/resources/images/avagato-small.png"

  cat > "$work/guac-manifest.json" <<'JSON'
{
  "guacamoleVersion":"1.6.0",
  "name":"Avagato Theme",
  "namespace":"avagato-dark-theme",
  "avagatoThemeVersion":"1.0.0",
  "css":["dark.css"],
  "js":["branding.js"],
  "resources":{
    "resources/images/avagato-login.png":"image/png",
    "resources/images/avagato-large.png":"image/png",
    "resources/images/avagato-small.png":"image/png"
  },
  "translations":["translations/en.json"]
}
JSON
  cat > "$work/translations/en.json" <<'JSON'
{"APP":{"NAME":"Avagato"}}
JSON
  cat > "$work/branding.js" <<'JS'
(function () {
    'use strict';

    function applyAvagatoBranding() {
        var iconPath = 'app/ext/avagato-dark-theme/resources/images/avagato-small.png';
        var largeIconPath = 'app/ext/avagato-dark-theme/resources/images/avagato-large.png';
        var icons = document.querySelectorAll('link[rel~="icon"]');
        var i;

        if (icons.length) {
            for (i = 0; i < icons.length; i++)
                icons[i].href = iconPath;
        }
        else {
            var icon = document.createElement('link');
            icon.rel = 'icon';
            icon.type = 'image/png';
            icon.href = iconPath;
            document.head.appendChild(icon);
        }

        var apple = document.querySelectorAll('link[rel="apple-touch-icon"]');
        for (i = 0; i < apple.length; i++)
            apple[i].href = largeIconPath;
    }

    if (document.readyState === 'loading')
        document.addEventListener('DOMContentLoaded', applyAvagatoBranding);
    else
        applyAvagatoBranding();
}());
JS
  cat > "$work/dark.css" <<'CSS'
/* Avagato Theme - Apache Guacamole 1.6.0 */
html,body,#content,.login-ui{background:#121416!important;color:#e5e7e9!important}.login-ui .login-dialog,.menu,.menu-content,.menu-body,.settings,.notification,.modal{background:#1c1f22!important;color:#e5e7e9!important}.header,.menu-content .header,.transfer-manager .header,#filesystem-menu .header{background:#24282c!important;color:#f1f3f4!important}h1,h2,h3,h4,h5,label,.caption,.field-header,.name,.description,p,span{color:inherit}a{color:#75baff}a:hover{color:#a8d4ff}input,select,textarea{background:#292d31!important;color:#f1f3f4!important;border-color:#4a5056!important}input:focus,select:focus,textarea:focus{background:#30353a!important;border-color:#6b9fc8!important}input:disabled,input[disabled],input[readonly],select:disabled,select[disabled],textarea:disabled,textarea[disabled]{background:#24282c!important;color:#9ca3af!important;border-color:#454b50!important;opacity:1!important}button,.button,input[type=submit]{background:#343a40!important;color:#f1f3f4!important;border-color:#555d64!important}button:hover,.button:hover,input[type=submit]:hover{background:#41484f!important}table,tbody,tr,td,th{color:#e5e7e9}.list-item{color:#e5e7e9!important}.list-item:hover{background:#292e32!important}.page-tabs,.page-tabs .page-list{background:#1c1f22!important;color:#e5e7e9!important}.page-tabs .page-list li a{color:#cfd3d6!important}.page-tabs .page-list li a:hover,.page-tabs .page-list li a.current{color:#fff!important;background:#292e32!important}.menu-section h3{color:#aeb5ba!important}.menu-dropdown,.menu-contents{background:#1c1f22!important;color:#e5e7e9!important}.user-menu .menu-contents,.user-menu .menu-contents li,.user-menu .menu-contents li a,.user-menu .menu-contents li a:visited,.user-menu .menu-contents li a:hover{color:#e5e7e9!important}.user-menu .menu-contents li a:hover{background:#30353a!important}.user-list .list-item,.user-list .list-item a,.user-list .list-item .name,.user-list .list-item .caption,.user-list .user a,.user-list .user a:visited,.user-list .username,.user-list .username a,.user-list td a,.user-list td a:visited{color:#e5e7e9!important}.logged-out-modal guac-modal,.automatic-login-rejected-modal guac-modal{background:#121416!important;color:#e5e7e9!important}.logged-out-modal .notification,.automatic-login-rejected-modal .notification{background:#1c1f22!important;color:#e5e7e9!important}.filter input,.search-field input,input[placeholder="Filter"]{background:#121416!important;color:#e5e7e9!important;border:1px solid #9ca3af!important;border-radius:4px!important}.filter input::placeholder,.search-field input::placeholder,input[placeholder="Filter"]::placeholder{color:#b8bec4!important;opacity:1!important}.filter input:focus,.search-field input:focus,input[placeholder="Filter"]:focus{background:#121416!important;color:#fff!important;border-color:#b9d7eb!important;outline:none!important}.location-chooser div.location{background:#292d31!important;color:#f1f3f4!important;border-color:#4a5056!important;cursor:pointer!important}.location-chooser div.location:hover{background:#30353a!important;border-color:#6b9fc8!important}.location-chooser .dropdown{background:#1c1f22!important;color:#e5e7e9!important;border-color:#4a5056!important}.location-chooser .dropdown .list-item,.location-chooser .dropdown .list-item .name,.location-chooser .dropdown .connection-group,.location-chooser .dropdown .connection-group .name{color:#e5e7e9!important}.location-chooser .dropdown .list-item:hover,.location-chooser .dropdown .list-item:not(.selected) .caption:hover{background:#30353a!important}.location-chooser .dropdown .list-item.selected{background:#343a40!important;color:#fff!important}.settings .connection .name,.settings .connection a,.settings .connection a:visited,.all-connections .connection a,.all-connections .connection a:visited,.all-connections .connection a:hover,.all-connections .connection .name,.recent-connections .connection a,.recent-connections .connection a:visited,.recent-connections .connection a:hover,.recent-connections .connection .name,.recent-connections .connection .caption{color:#e5e7e9!important}.recent-connections .connection:hover,.all-connections .list-item:not(.selected) .caption:hover{background:#30353a!important;color:#fff!important}.recent-connections .connection:hover a,.recent-connections .connection:hover .name,.recent-connections .connection:hover .caption,.all-connections .list-item:not(.selected) .caption:hover,.all-connections .list-item:not(.selected) .caption:hover .name,.all-connections .list-item:not(.selected) .caption:hover a{color:#fff!important}.settings .connection:hover,.settings .list-item:not(.selected) .caption:hover{background:#30353a!important;color:#fff!important}.settings .connection:hover a,.settings .connection:hover .name,.settings .connection:hover .caption,.settings .list-item:not(.selected) .caption:hover,.settings .list-item:not(.selected) .caption:hover .name,.settings .list-item:not(.selected) .caption:hover a{color:#fff!important}.login-ui .login-fields .labeled-field .field-header{color:#b8bec4!important;opacity:1!important}.login-ui .login-fields .labeled-field.empty input{background:transparent!important}.login-ui .login-fields .labeled-field input:focus{background:#30353a!important}.client,.client .display,.viewport{color:initial}hr{border-color:#3b4146!important}

/* Avagato branding. Assets are served by Guacamole's extension resource handler. */
.login-ui .login-dialog .logo{
    width:18em!important;
    height:15em!important;
    max-width:100%!important;
    margin:-1.5em auto -1em!important;
    background-image:url('app/ext/avagato-dark-theme/resources/images/avagato-login.png')!important;
    background-position:center!important;
    background-repeat:no-repeat!important;
    background-size:contain!important
}
.login-ui .login-dialog .app-name{display:none!important}
CSS
  (cd "$work" && jar cf "$out" guac-manifest.json dark.css branding.js translations resources)
)

