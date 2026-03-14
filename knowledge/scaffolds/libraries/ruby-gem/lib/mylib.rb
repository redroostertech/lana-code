# frozen_string_literal: true

require_relative "mylib/version"

# MyLib provides reusable utility functions.
module MyLib
  class Error < StandardError; end

  # Add two numbers together.
  #
  # @param a [Numeric] first number
  # @param b [Numeric] second number
  # @return [Numeric] the sum
  def self.add(a, b)
    a + b
  end

  # Generate a greeting string.
  #
  # @param name [String] the name to greet
  # @param greeting [String] the greeting prefix (default: "Hello")
  # @return [String] the greeting
  # @raise [Error] if name is empty
  def self.greet(name, greeting: "Hello")
    raise Error, "name must not be empty" if name.nil? || name.empty?

    "#{greeting}, #{name}!"
  end
end
