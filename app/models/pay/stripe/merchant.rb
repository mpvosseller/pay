module Pay
  module Stripe
    class Merchant < Pay::Merchant
      def create_account(**options)
        stripe_account = ::Stripe::Account.create(options)
        update(processor_id: stripe_account.id)
        stripe_account
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      def account
        ::Stripe::Account.retrieve(processor_id)
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      def account_link(refresh_url:, return_url:, type: "account_onboarding", **options)
        ::Stripe::AccountLink.create({
          account: processor_id,
          refresh_url: refresh_url,
          return_url: return_url,
          type: type
        }.merge(options))
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      # A single-use login link for Express accounts to access their Stripe dashboard
      def login_link(**options)
        ::Stripe::Account.create_login_link(processor_id)
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      # Transfer money from the platform to this connected account
      # https://stripe.com/docs/connect/charges-transfers#transfer-availability
      def transfer(amount:, currency: "usd", **options)
        ::Stripe::Transfer.create({
          amount: amount,
          currency: currency,
          destination: processor_id
        }.merge(options))
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end
    end
  end
end

ActiveSupport.run_load_hooks :pay_stripe_merchant, Pay::Stripe::Merchant
