Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  resources :meal_entries, except: %i[ index show ]

  # Pick a recent household meal and log it at your own portion (WP6a).
  resources :repeats, only: %i[ index show ]
  post "repeats/:id" => "repeats#create", as: :log_repeat

  # A food nobody has eaten yet needs a portion screen keyed on the food itself (WP4.4).
  # The repeat picker's is keyed on an entry and the scanner's on a barcode, so between
  # them they can reach everything except a row that has only a name and its macros —
  # which is every imported recipe.
  resources :foods, only: %i[ show ]
  post "foods/:id" => "foods#create", as: :log_food

  # Scan a barcode and log a portion of what the label says (WP7). The barcode is the
  # id here rather than a `foods` id: at scan time we may not have a row for it yet,
  # and after the manual fallback the same URL has to keep working.
  get "scan" => "scans#new", as: :scan

  # Typed entry posts here rather than being intercepted in JS, so the fallback path
  # does not itself depend on the scripting that just failed. "lookup" is not digits,
  # so it can never collide with the :barcode routes below.
  get "scan/lookup" => "scans#lookup", as: :lookup_scan

  scope constraints: { barcode: /\d{6,14}/ } do
    get "scan/:barcode" => "scans#show", as: :scanned
    post "scan/:barcode" => "scans#create", as: :log_scan
    post "scan/:barcode/food" => "scans#adopt", as: :adopt_scan
  end

  # The chat is one thread per user, so it's a singular resource with no id in the URL.
  get "chat" => "chats#show", as: :chat
  post "chat/messages" => "chat_messages#create", as: :chat_messages
  post "chat/suggestions/:id/accept" => "chat_suggestions#accept", as: :accept_chat_suggestion
  post "chat/suggestions/:id/decline" => "chat_suggestions#decline", as: :decline_chat_suggestion

  get "days/:date", to: "days#show", as: :day, constraints: { date: /\d{4}-\d{2}-\d{2}/ }
  root "days#show"

  # The implementation plan, rendered from doc/ for the household to read.
  # Signed-in only — it is not published anywhere.
  get "plan" => "plan#show"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*. The service worker is served
  # from the root so its scope covers the whole app.
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
