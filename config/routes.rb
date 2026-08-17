Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  resources :meal_entries, except: %i[ index show ]

  get "days/:date", to: "days#show", as: :day, constraints: { date: /\d{4}-\d{2}-\d{2}/ }
  root "days#show"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # Enabled in WP2.
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
