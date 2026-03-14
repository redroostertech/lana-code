# frozen_string_literal: true

require_relative "lib/mylib/version"

Gem::Specification.new do |spec|
  spec.name          = "mylib"
  spec.version       = MyLib::VERSION
  spec.authors       = ["Author Name"]
  spec.email         = ["author@example.com"]

  spec.summary       = "A reusable Ruby library"
  spec.description   = "A reusable Ruby library with utility functions."
  spec.homepage      = "https://github.com/user/mylib"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir.chdir(__dir__) do
    Dir["{lib}/**/*", "LICENSE", "README.md"]
  end

  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.0"
end
