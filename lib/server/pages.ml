(* Server-rendered pages: the login form, the first-run account setup form and
   the fallback page shown when the UI assets are missing.

   These are plain HTML forms that work without JavaScript, like Sonarr's and
   Radarr's login page. They are styled with the same stylesheet as the app. *)

let escape s =
  let buffer = Buffer.create (String.length s + 16) in
  String.iter
    (fun c ->
      match c with
      | '&' -> Buffer.add_string buffer "&amp;"
      | '<' -> Buffer.add_string buffer "&lt;"
      | '>' -> Buffer.add_string buffer "&gt;"
      | '"' -> Buffer.add_string buffer "&quot;"
      | '\'' -> Buffer.add_string buffer "&#39;"
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.contents buffer

let shell ~title body =
  Printf.sprintf
    {|<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>%s</title>
    <link rel="stylesheet" href="/static/style.css" />
  </head>
  <body class="auth-body">
    <main class="auth-shell">
      <div class="auth-card">
        <h1 class="auth-logo">Pickarr</h1>
        %s
      </div>
    </main>
  </body>
</html>
|}
    (escape title) body

let message_block = function
  | None -> ""
  | Some (kind, text) ->
      Printf.sprintf {|<p class="auth-message %s">%s</p>|} kind (escape text)

(** The login page. [csrf] is the hidden input produced by [Dream.csrf_tag]. *)
let login ~csrf ?message ?(username = "") () =
  shell ~title:"Sign in — Pickarr"
    (Printf.sprintf
       {|<p class="hint">Sign in to continue.</p>
        %s
        <form method="POST" action="/login">
          %s
          <label>User name
            <input type="text" name="username" autocomplete="username" autofocus value="%s" required />
          </label>
          <label>Password
            <input type="password" name="password" autocomplete="current-password" required />
          </label>
          <label class="inline">
            <input type="checkbox" name="remember" value="1" /> Remember me
          </label>
          <button class="primary block" type="submit">Sign in</button>
        </form>|}
       (message_block message) csrf (escape username))

(** The one-time "Create admin account" page, shown before anything else when
    no account exists. *)
let setup ~csrf ?message () =
  shell ~title:"Create your account — Pickarr"
    (Printf.sprintf
       {|<h2 class="auth-title">Create admin account</h2>
        <p class="hint">
          Pickarr decides which releases your Sonarr and Radarr grab, so it needs
          an account before it can be used. This page is shown only once.
        </p>
        %s
        <form method="POST" action="/setup">
          %s
          <label>User name
            <input type="text" name="username" autocomplete="username" autofocus value="admin" required />
          </label>
          <label>Password <span class="hint-inline">at least 8 characters</span>
            <input type="password" name="password" autocomplete="new-password" required />
          </label>
          <label>Confirm password
            <input type="password" name="confirm" autocomplete="new-password" required />
          </label>
          <button class="primary block" type="submit">Create account</button>
        </form>|}
       (message_block message) csrf)

(** Shown when a browser reaches the UI but the static assets are absent. *)
let ui_missing =
  shell ~title:"Pickarr"
    {|<p>The web UI assets were not found.</p>
      <p class="hint">
        The API is still available under <code>/api</code> and
        <code>/health</code>. Set <code>STATIC_DIR</code> to the directory that
        contains <code>index.html</code>.
      </p>|}
