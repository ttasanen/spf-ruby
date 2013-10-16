require 'ip'
require 'resolv'

require 'spf/model'

class SPF::Server

  attr_accessor \
    :default_authority_explanation,
    :hostname,
    :dns_resolver,
    :query_rr_types,
    :max_dns_interactive_terms,
    :max_name_lookups_per_term,
    :max_name_lookups_per_mx_mech,
    :max_name_lookups_per_ptr_mech,
    :max_void_dns_lookups

  RECORD_CLASSES_BY_VERSION = {
    1 => SPF::Record::V1,
    2 => SPF::Record::V2
  }

  RESULT_BASE_CLASS = SPF::Result

  QUERY_RR_TYPE_ALL = 0
  QUERY_RR_TYPE_TXT = 1
  QUERY_RR_TYPE_SPF = 2

  DEFAULT_DEFAULT_AUTHORITY_EXPLANATION =
    'Please see http://www.openspf.org/Why?s=%{_scope};id=%{S};ip=%{C};r=%{R}'

  DEFAULT_MAX_DNS_INTERACTIVE_TERMS     = 10 # RFC 4408, 10.1/6
  DEFAULT_MAX_NAME_LOOKUPS_PER_TERM     = 10 # RFC 4408, 10.1/7
  DEFAULT_QUERY_RR_TYPES                = QUERY_RR_TYPE_TXT
  DEFAULT_MAX_NAME_LOOKUPS_PER_MX_MECH  = MAX_NAME_LOOKUPS_PER_TERM
  DEFAULT_MAX_NAME_LOOKUPS_PER_PTR_MECH = MAX_NAME_LOOKUPS_PER_TERM
  DEFAULT_MAX_VOID_DNS_LOOKUPS          = 2

  def initialize(options = {})
    @default_authority_explanation = options[:default_authority_explanation] ||
      DEFAULT_DEFAULT_AUTHORITY_EXPLANATION
    unless @default_authority_explanation.is_a?(SPF::MacroString)
      @default_authority_explanation = SPF::MacroString.new({
        :text           => @default_authority_explanation,
        :server         => self,
        :is_explanation => true
      })
    end
    @hostname                      = options[:hostname]     || SPF::Util.hostname
    @dns_resolver                  = options[:dns_resolver] || Resolv::DNS.new
    @query_rr_types                = options[:query_rr_types]                ||
      DEFAULT_QUERY_RR_TYPES
    @max_dns_interactive_terms     = options[:max_dns_interactive_terms]     ||
      DEFAULT_MAX_DNS_INTERACTIVE_TERMS
    @max_name_lookups_per_term     = options[:max_name_lookups_per_term]     ||
      DEFAULT_MAX_NAME_LOOKUPS_PER_TERM
    @max_name_lookups_per_mx_mech  = options[:max_name_lookups_per_mx_mech]  ||
      DEFAULT_MAX_NAME_LOOKUPS_PER_MX_MECH
    @max_name_lookups_per_ptr_mech = options[:max_name_lookups_per_ptr_mech] ||
      DEFAULT_MAX_NAME_LOOKUPS_PER_PTR_MECH
    @max_void_dns_lookups          = options[:max_void_dns_lookups]          ||
      DEFAULT_MAX_VOID_DNS_LOOKUPS
  end

  def result_class(name = nil)
    if name
      return RESULT_BASE_CLASS.result_classes[name]
    else
      return RESULT_BASE_CLASS
    end
  end

  def process(request)
    request.state(:authority_explanation,      nil)
    request.state(:dns_interactive_term_count, 0)
    request.state(:void_dns_lookups_count,     0)

    result = nil

    begin
      record = self.select_record(request)
      request.record(record)
      record.eval(self, request)
    rescue SPF::Result => r
      result = r
    rescue SPF::DNSError => e
      result = self.result_class('temperror').new(self, request, e.text)
    rescue SPF::NoAcceptableRecordError => e
      result = self.result_class('none'     ).new(self, request, e.text)
    rescue SPF::RedundantAcceptableRecordsError, SPF::SyntaxError, SPF::ProcessingLimitExceededError => e
      result = self.result_class('permerror').new(self, request, e.text)
    end
    # Propagate other, unknown errors.
    # This should not happen, but if it does, it helps exposing the bug!

    return result
  end

  def select_record(request)
    domain   = request.authority_domain
    versions = request.versions
    scope    = request.scope

    # Employ identical behavior for 'v=spf1' and 'spf2.0' records, both of
    # which support SPF (code 99) and TXT type records (this may be different
    # in future revisions of SPF):
    # Query for SPF type records first, then fall back to TXT type records.

    records     = []
    query_count = 0
    dns_errors  = []

    # Query for SPF-type RRs first:
    if (@query_rr_types == QUERY_RR_TYPE_ALL or
        @query_rr_types & QUERY_RR_TYPE_SPF)
      begin
        query_count += 1
        packet = self.dns_lookup(domain, 'SPF')
        records << self.get_acceptable_records_from_packet(
          packet, 'SPF', versions, scope, domain)
      rescue SPF::DNSError => e
        dns_errors << e
      #rescue SPF::DNSTimeout => e
      #  # FIXME: Ignore DNS timeouts on SPF type lookups?
      #  # Apparently some brain-dead DNS servers time out on SPF-type queries.
      end
    end

    if (not records.any? and
        @query_rr_types == QUERY_RR_TYPES_ALL or
        @query_rr_types & QUERY_RR_TYPE_TXT)
      # NOTE:
      #   This deliberately violates RFC 4406 (Sender ID), 4.4/3 (4.4.1):
      #   TXT-type RRs are still tried if there _are_ SPF-type RRs but all
      #   of them are inapplicable (e.g. "Hi!", or even "spf2/pra" for an
      #   'mfrom' scope request).  This conforms to the spirit of the more
      #   sensible algorithm in RFC 4408 (SPF), 4.5.
      #   Implication:  Sender ID processing may make use of existing TXT-
      #   type records where a result of "None" would normally be returned
      #   under a strict interpretation of RFC 4406.
     
      begin
        query_count += 1
        packet = self.dns_lookup(domain, 'TXT')
        records << self.get_acceptable_records_from_packet(
          packet, 'TXT', versions, scope, domain)
      rescue SPF::DNSError => e
        dns_errors << e
      end

      # Unless at least one query succeeded, re-raise the first DNS error that occured.
      raise dns_errors[0] unless dns_errors.length < query_count

      if records.empty?
        # RFC 4408, 4.5/7
        raise SPF::NoAcceptableRecordError('No applicable sender policy available')
      end

      # Discard all records but the highest acceptable version:
      preferred_record_class = records[0].class
      records = records.select { |record| record.is_a?(preferred_record_class) }

      if records.length != 1
        # RFC 4408, 4.5/6
        raise SPF::RedundantAcceptableRecordsError.new(
          "Redundant applicable '#{preferred_record_class.version_tag}' sender policies found"
        )
      end

      return records[0]
    end

    def get_acceptable_records_from_packet(packet, rr_type, versions, scope, domain)

      # Try higher record versions first.
      # (This may be too simplistic for future revisions of SPF.)
      versions = versions.sort { |x, y| y <=> x }

      records = []
      packet.answer.each do |rr|
        next if rr.type != rr_type
        text = rr.char_str_list.join('')
        record = false
        versions.each do |version|
          klass = RECORD_CLASSES_BY_VERSION[version]
          begin
            record = klass.new_from_string(text)
          rescue SPF::InvalidRecordVersion
            # Ignore non-SPF and unknown-version records.
            # Propagate other errors (including syntax errors), though.
          end
        end
        if record
          if record.SCOPES.select{|x| scope == x}.any?
            # Record covers requested scope.
            records << record
          end
          break
        end
      end
      return records
    end

    # FIXME: This needs to be changed to use the Ruby resolver library properly.
    def dns_lookup(domain, rr_type)
      if domain.is_a?(SPF::MacroString)
        domain = domain.expand
        # Truncate overlong labels at 63 bytes (RFC 4408, 8.1/27)
        domain.gsub!(/([^.]{63})[^.]+/, "#{$1}")
        # Drop labels from the head of domain if longer than 253 bytes (RFC 4408, 8.1/25):
        domain.sub!(/^[^.]+\.(.*)$/, "#{$1}") while domain.length > 253
      end

      domain.sub(/^(.*?)\.?$/, $1 ? "#{$1}".downcase : '')

      packet = @dns_resolver.send(domain, rr_type)

      # Raise DNS exception unless an answer packet with RCODE 0 or 3 (NXDOMAIN)
      # was received (thereby treating NXDOMAIN as an acceptable but empty answer packet):
      if @dns_resolver.errorstring =~ /^(timeout|query timed out)$/
        raise SPF::DNSTimeoutError.new(
          "Time-out on DNS '#{rr_type}' lookup of '#{domain}'")
      end

      unless packet
        raise SPF::DNSError.new(
          "Unknown error on DNS '#{rr_type}' lookup of '#{domain}'")
      end

      unless packet.header.rcode =~ /^(NOERROR|NXDOMAIN)$/
        raise SPF::DNSError.new(
          "'#{packet.header.rcode}' error on DNS '#{rr_type}' lookup of '#{domain}'")
      end
      return packet
    end

    def count_dns_interactive_term(request)
      n = 1
      dns_interactive_terms_count = request.root_request.state(:dns_interactive_terms_count, 1)
      if (@max_dns_interactive_terms and
          dns_interactive_terms_count > @max_dns_interactive_terms)
        raise SPF::ProcessingLimitExceeded.new(
          "Maximum DNS-interactive terms limit (#{@max_dns_interactive_terms}) exceeded")
      end
    end

    def count_void_dns_lookup(request)
      void_dns_lookups_count = request.root_request.state(:void_dns_lookups_count, 1)
      if (@max_void_dns_lookups and
          void_dns_lookups_count > @max_void_dns_lookups)
        raise SPF::ProcessingLimitExceeded.new(
          "Maximum void DNS look-ups limit (#{@max_void_dns_lookups}) exceeded")
      end
    end
  end
end