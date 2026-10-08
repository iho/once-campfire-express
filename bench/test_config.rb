require "minitest/autorun"
require_relative "support"

class BenchmarkConfigTest < Minitest::Test
  HELPERS = Object.new.extend(BenchmarkSupport)

  def test_counts_single_and_disjoint_cpu_ranges
    assert_equal 4, HELPERS.cpuset_cpu_count("8-11")
    assert_equal 5, HELPERS.cpuset_cpu_count("0-1,4,7-8")
    assert_equal 1, HELPERS.cpuset_cpu_count("3")
  end

  def test_rejects_malformed_and_overlapping_cpu_ranges
    assert_raises(ArgumentError) { HELPERS.cpuset_cpu_count("4-2") }
    assert_raises(ArgumentError) { HELPERS.cpuset_cpu_count("0-2,2-4") }
    assert_raises(ArgumentError) { HELPERS.cpuset_cpu_count("0,,2") }
  end

  def test_domain_count_matches_linux_cpu_allocation
    assert_equal 4, HELPERS.oxcaml_domain_count(cpu_set: "8-11", linux_host: true, overrides: {})
    assert_equal 1, HELPERS.oxcaml_domain_count(cpu_set: "0-3", linux_host: false, overrides: {})
    assert_equal 2, HELPERS.oxcaml_domain_count(cpu_set: "8-11", linux_host: true, overrides: {"WEB_WORKERS" => "2"})
  end

  def test_domain_count_rejects_invalid_overrides
    ["0", "65", "four", true].each do |value|
      assert_raises(ArgumentError) do
        HELPERS.oxcaml_domain_count(cpu_set: "0-3", linux_host: true, overrides: {"WEB_WORKERS" => value})
      end
    end
  end
end
