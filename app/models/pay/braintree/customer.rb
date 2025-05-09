module Pay
  module Braintree
    class Customer < Pay::Customer
      has_many :charges, dependent: :destroy, class_name: "Pay::Braintree::Charge"
      has_many :subscriptions, dependent: :destroy, class_name: "Pay::Braintree::Subscription"
      has_many :payment_methods, dependent: :destroy, class_name: "Pay::Braintree::PaymentMethod"
      has_one :default_payment_method, -> { where(default: true) }, class_name: "Pay::Braintree::PaymentMethod"

      # Returns a hash of attributes for the Stripe::Customer object
      def api_record_attributes
        attributes = case owner.class.pay_braintree_customer_attributes
        when Symbol
          owner.send(owner.class.pay_braintree_customer_attributes, self)
        when Proc
          owner.class.pay_braintree_customer_attributes.call(self)
        end

        first_name, last_name = customer_name.split(" ", 2)
        {email: email, first_name: first_name, last_name: last_name}.merge(attributes || {})
      end

      # Retrieve the Braintree::Customer object
      #
      # - If no processor_id is present, creates a Customer.
      def api_record
        if processor_id?
          gateway.customer.find(processor_id)
        else
          result = gateway.customer.create(api_record_attributes)
          raise Pay::Braintree::Error, result unless result.success?
          update!(processor_id: result.customer.id)
          result.customer
        end
      rescue ::Braintree::AuthorizationError => e
        raise Pay::Braintree::AuthorizationError, e
      rescue ::Braintree::BraintreeError => e
        raise Pay::Braintree::Error, e
      end

      # Syncs name and email to Braintree::Customer
      # You can also pass in other attributes that will be merged into the default attributes
      def update_api_record(**attributes)
        api_record unless processor_id?
        gateway.customer.update(processor_id, api_record_attributes.merge(attributes))
      end

      def charge(amount, options = {})
        args = {
          amount: amount.to_i / 100.0,
          customer_id: processor_id || api_record.id,
          options: {submit_for_settlement: true},
          custom_fields: options.delete(:metadata)
        }.merge(options)

        result = gateway.transaction.sale(args)
        raise Pay::Braintree::Error, result unless result.success?

        save_transaction(result.transaction)
      rescue ::Braintree::AuthorizationError => e
        raise Pay::Braintree::AuthorizationError, e
      rescue ::Braintree::BraintreeError => e
        raise Pay::Braintree::Error, e
      end

      def subscribe(name: Pay.default_product_name, plan: Pay.default_plan_name, **options)
        token = api_record.payment_methods.find(&:default?).try(:token)
        raise Pay::Error, "Customer has no default payment method" if token.nil?

        # Standardize the trial period options
        if (trial_period_days = options.delete(:trial_period_days)) && trial_period_days > 0
          options.merge!(trial_period: true, trial_duration: trial_period_days, trial_duration_unit: :day)
        end

        metadata = options.delete(:metadata)
        subscription_options = options.merge(payment_method_token: token, plan_id: plan)

        result = gateway.subscription.create(subscription_options)
        raise Pay::Braintree::Error, result unless result.success?

        # Braintree returns dates without time zones, so we'll assume they're UTC
        trial_end_date = result.subscription.trial_period.present? ? result.subscription.first_billing_date.end_of_day : nil

        subscription = subscriptions.create!(
          name: name,
          processor_id: result.subscription.id,
          processor_plan: plan,
          status: :active,
          trial_ends_at: trial_end_date,
          ends_at: nil,
          metadata: metadata
        )

        if (charge = result.subscription.transactions.first)
          save_transaction(charge)
        end

        subscription
      rescue ::Braintree::AuthorizationError => e
        raise Pay::Braintree::AuthorizationError, e
      rescue ::Braintree::BraintreeError => e
        raise Pay::Braintree::Error, e
      end

      def add_payment_method(token, default: false)
        result = gateway.payment_method.create(
          customer_id: processor_id || api_record.id,
          payment_method_nonce: token,
          options: {
            make_default: default,
            verify_card: true
          }
        )
        raise Pay::Braintree::Error, result unless result.success?

        pay_payment_method = save_payment_method(result.payment_method, default: default)

        # Update existing subscriptions to the new payment method
        subscriptions.each do |subscription|
          if subscription.active?
            gateway.subscription.update(subscription.processor_id, {payment_method_token: token})
          end
        end

        pay_payment_method
      rescue ::Braintree::AuthorizationError => e
        raise Pay::Braintree::AuthorizationError, e
      rescue ::Braintree::BraintreeError => e
        raise Pay::Braintree::Error, e
      end

      def save_transaction(transaction)
        attrs = card_details_for_braintree_transaction(transaction)
        attrs[:amount] = transaction.amount.to_f * 100
        attrs[:metadata] = transaction.custom_fields
        attrs[:currency] = transaction.currency_iso_code
        attrs[:application_fee_amount] = transaction.service_fee_amount
        attrs[:created_at] = transaction.created_at

        # Associate charge with subscription if we can
        if transaction.subscription_id
          pay_subscription = subscriptions.find_by(processor_id: transaction.subscription_id)
          pay_subscription ||= Pay::Braintree::Subscription.sync(transaction.subscription_id)

          if pay_subscription
            attrs[:subscription] = pay_subscription
            attrs[:metadata] = pay_subscription.metadata
          end
        end

        charge = Pay::Braintree::Charge.find_or_initialize_by(customer: self, processor_id: transaction.id)
        charge.update!(attrs)
        charge
      end

      def gateway
        Pay.braintree_gateway
      end

      def save_payment_method(payment_method, default:)
        attributes = case payment_method
        when ::Braintree::CreditCard, ::Braintree::ApplePayCard, ::Braintree::GooglePayCard, ::Braintree::SamsungPayCard, ::Braintree::VisaCheckoutCard
          {
            payment_method_type: :card,
            brand: payment_method.card_type,
            last4: payment_method.last_4,
            exp_month: payment_method.expiration_month,
            exp_year: payment_method.expiration_year
          }

        when ::Braintree::PayPalAccount
          {
            payment_method_type: :paypal,
            brand: "PayPal",
            email: payment_method.email
          }
        when ::Braintree::VenmoAccount
          {
            payment_method_type: :venmo,
            brand: "Venmo",
            username: payment_method.username
          }
        when ::Braintree::UsBankAccount
          {
            payment_method_type: "us_bank_account",
            bank: payment_method.bank_name,
            last4: payment_method.last_4
          }
        else
          {
            payment_method_type: payment_method.class.name.demodulize.underscore,
            brand: payment_method.try(:card_type),
            last4: payment_method.try(:last_4),
            exp_month: payment_method.try(:expiration_month),
            exp_year: payment_method.try(:expiration_year),
            bank: payment_method.try(:bank_name),
            username: payment_method.try(:username),
            email: payment_method.try(:email)
          }
        end

        pay_payment_method = payment_methods.where(processor_id: payment_method.token).first_or_initialize

        payment_methods.update_all(default: false) if default
        pay_payment_method.update!(attributes.merge(default: default))

        # Reload the Rails association
        reload_default_payment_method if default

        pay_payment_method
      end

      def card_details_for_braintree_transaction(transaction)
        case transaction.payment_instrument_type
        when "android_pay_card", "apple_pay_card", "credit_card", "google_pay_card", "samsung_pay_card", "visa_checkout_card"
          # Lookup the attribute with the payment method details by name
          attribute_name = transaction.payment_instrument_type

          # The attribute name for Apple and Google Pay don't include _card for some reason
          if ["apple_pay_card", "google_pay_card"].include?(transaction.payment_instrument_type)
            attribute_name = attribute_name.split("_card").first

          # Android Pay was renamed to Google Pay, but test nonces still use android_pay_card
          elsif attribute_name == "android_pay_card"
            attribute_name = "google_pay"
          end

          # Retrieve payment method details from transaction
          payment_method = transaction.send(:"#{attribute_name}_details")

          {
            payment_method_type: :card,
            brand: payment_method.card_type,
            last4: payment_method.last_4,
            exp_month: payment_method.expiration_month,
            exp_year: payment_method.expiration_year
          }

        when "paypal_account"
          {
            payment_method_type: :paypal,
            brand: "PayPal",
            email: transaction.paypal_details.payer_email,
            last4: transaction.paypal_details.payer_email,
            exp_month: nil,
            exp_year: nil
          }

        when "venmo_account"
          {
            payment_method_type: :venmo,
            brand: "Venmo",
            username: transaction.venmo_account_details.username,
            last4: transaction.venmo_account_details.username,
            exp_month: nil,
            exp_year: nil
          }

        else
          {payment_method_type: "unknown"}
        end
      end
    end
  end
end

ActiveSupport.run_load_hooks :pay_braintree_customer, Pay::Braintree::Customer
