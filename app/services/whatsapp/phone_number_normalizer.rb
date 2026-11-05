# frozen_string_literal: true

# Whatsapp::PhoneNumberNormalizer
#
# Single source of truth for normalizing a phone number into the canonical form
# WhatsApp itself resolves to. This is a faithful port of Evolution API's
# `createJid` logic (evolution-api/src/utils/createJid.ts) — the same rules the
# gateway applies before talking to WhatsApp — so that contacts created in the
# CRM (leads API, widget, import) and contacts seen via inbound WhatsApp messages
# converge on ONE string and stop duplicating.
#
# Covers the three countries with an "extra digit" quirk:
#   - Brazil (+55):  the nono dígito. Kept for every mobile: DDD <= 30 already
#                    came with 13 digits, and a 12-digit number whose subscriber
#                    starts 6-9 gets the 9 inserted. Landlines (subscriber
#                    starting 2-5) stay 12 digits.
#   - Mexico (+52):  the leading "1" after the country code on 13-digit numbers.
#   - Argentina (+54): the leading "9" after the country code on 13-digit numbers.
#
# Returns DIGITS ONLY (no '+', no '@s.whatsapp.net'). Callers that persist E.164
# prepend '+' themselves; callers that build a JID append the suffix.
#
# Numbers from any other country, group JIDs, or strings that don't match the
# expected shape are returned with only cosmetic cleanup (non-digits removed),
# i.e. the function is a safe pass-through — never raises.
class Whatsapp::PhoneNumberNormalizer
  def self.call(raw)
    new(raw).call
  end

  # Convenience for lookup/persist paths that store E.164 ('+<digits>'). Returns
  # nil for blank/uninormalizable input so callers can guard a find_by cleanly.
  def self.to_e164(raw)
    digits = call(raw)
    return nil if digits.blank?

    "+#{digits}"
  end

  def initialize(raw)
    @raw = raw.to_s
  end

  # @return [String, nil] digits-only normalized number, or nil for blank input.
  def call
    return nil if @raw.strip.empty?

    number = strip_to_digits(@raw)
    return number if number.empty?

    number = format_mx_or_ar(number)
    format_br(number)
  end

  private

  # Mirrors createJid's cleanup: drop whitespace, '+', parens, ':' suffix and any
  # JID domain, then keep only digits.
  def strip_to_digits(value)
    value.gsub(/\s/, '')
         .delete('+()')
         .split(':').first.to_s
         .split('@').first.to_s
         .gsub(/\D/, '')
  end

  # Port of formatMXOrARNumber: for MX (52) / AR (54), a 13-digit number carries
  # an extra leading digit right after the country code — drop it.
  def format_mx_or_ar(number)
    country_code = number[0, 2]
    return number unless %w[52 54].include?(country_code)
    return number unless number.length == 13

    country_code + number[3..]
  end

  # Brazil stores the nono dígito. A 13-digit number already carries it; on a
  # 12-digit WhatsApp JID it is restored after the DDD unless the subscriber
  # looks like a landline (prefix 2-5). This is a superset of Evolution's
  # createJid: the JID already comes with the 9, and the stored contact no
  # longer loses it just because the DDD is >= 31.
  def format_br(number)
    match = /\A(\d{2})(\d{2})(\d{8})\z/.match(number)
    return number unless match

    country, ddd, subscriber = match[1], match[2], match[3]
    return number unless country == '55'
    return number if subscriber[0].to_i.between?(2, 5)

    country + ddd + '9' + subscriber
  end
end
