Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  resources :meal_entries, except: %i[ index show ]

  # Pick a recent household meal and log it at your own portion (WP6a).
  resources :repeats, only: %i[ index show ]
  post "repeats/:id" => "repeats#create", as: :log_repeat

  # The chat is one thread per user, so it's a singular resource with no id in the URL.
  get "chat" => "chats#show", as: :chat
  post "chat/messages" => "chat_messages#create", as: :chat_messages

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
