module Pay
  module Stripe
    module Webhooks
      class CustomerUpdated
        def call(event)
          object = event.data.object
          pay_customer = Pay::Customer.find_by(processor: :stripe, processor_id: object.id)

          # Couldn't find user, we can skip
          return unless pay_customer.present?

          stripe_customer = pay_customer.api_record

          attributes = {
            object: stripe_customer.to_hash
          }

          # Sync invoice credit balance and currency
          if stripe_customer.invoice_credit_balance.present?
            attributes[:invoice_credit_balance] = stripe_customer.invoice_credit_balance
            attributes[:currency] = stripe_customer.currency
          end

          pay_customer.update(attributes)

          # Sync default card
          if (payment_method_id = stripe_customer.invoice_settings.default_payment_method)
            Pay::Stripe::PaymentMethod.sync(payment_method_id, stripe_account: event.try(:account))

          else
            # No default payment method set
            pay_customer.payment_methods.update_all(default: false)
          end
        end
      end
    end
  end
end
