# Guidelines for Claude

## Software Development Best Practices
- Prefer composition over inheritance.
- Favor small classes and methods. Single Responsibility Principle.
- Depend on abstractions, not concretions.
- Write code that is easy to change. Anticipate future requirements.
- Use tests to drive design. Write tests that are easy to read and maintain.
- Refactor mercilessly. Continuously improve code quality.
- Prefer duck typing over rigid type hierarchies.
- Use dependency injection to manage dependencies.

## Ruby
- Write modern, idiomatic Ruby code. Use newer language features where appropriate.
- One class or module per file. File names should match class/module names. Error subclasses can be grouped with their parent.
- Use conventional mixins like `Enumerable`, `Forwardable`, and standard method names like `#succ`, `#call`, `#to_h`, etc. to integrate with other Ruby code cleanly.
- Make apropriate use of inheritance and modules to promote code reuse. DRY! 
- Use keyword argument over positional arguments whenever appropriate.
- Use `attr_accessor` and related methods to define getters and setters.
  - Use private accessors for reading internal state, never instance variables directly.
  - `#initialize` is the exception, where instance variables can be set directly.
- Metaprogramming is good, but avoid overusing it to the point where code becomes hard to understand.
  - `define_method` for `?` methods off of enumurated values is good
  - `method_missing` to dynamically handle all method calls is bad, use explicit forwarding / delegation
- Make use of `tap` and `then` to avoid temporary variables when appropriate.
- Use `when...then...` syntax with single-line case statements for conciseness
- Use Constants for regular expressions, and use `/x` mode for complex regexes
- Any given line of feature code will do one of 4 things:
  - Collecting input
    - Use keyword arguments to assert required inputs and provide defaults.
    - Prefer value objects over primitive types. Encapsulate behavior with data.
    - Provide clear interfaces for input. Use parameter builders when apropriate.
    - Use `Array()` and other conversion methods to handle flexible input types.
    - Define conversion functions where apropriate
  - Performing work
  - Delivering output
    - Handle special cases with a guard clause
  - Handling errors
    - Prefer top-level `rescue` clauses for error handling.
