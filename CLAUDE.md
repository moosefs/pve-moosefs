# Guidelines for Claude Code

## Project Overview
[TODO: Add project description here]

## Rules
- **Consult README.md** for context whenever needed
- **Test Driven Development** - Write tests before implementing ANY code or feature, no matter how small. We aim for high code coverage from the beginning.
- **Zero Placeholders** - Do not put in references to commands or functionality that are not implemented yet or do not exist
- **Modularity** - Break down components into small, focused files (typically <200 LoC per file)
- **Test Modularity** - Tests should be modular and organized for easy understanding and maintenance
- **"DO NOT SIMPLIFY - EVER"** - When thinking of simplifying something, think through the change deeply and ask the user what they want to do
- **Commit Regularly** - Test after every change and commit very regularly with tiny atomic chunks
- **Follow Language Style Guides** - Adhere to the style guide of your primary language
- **Use Palace Tools** - Use `pal test`, `pal build`, `pal run` for development workflows

## Quality Standards
- Write comprehensive tests for all new features
- Keep functions small and focused
- Use meaningful variable and function names
- Document complex logic with clear comments
- Handle errors gracefully with proper error messages

## Development Workflow
1. **Understand Requirements** - Read README.md and existing code
2. **Write Tests First** - Create failing tests that define expected behavior
3. **Implement Features** - Write minimal code to make tests pass
4. **Refactor** - Clean up code while keeping tests green
5. **Commit** - Small, atomic commits with clear messages

## Palace Integration
This project uses Palace (`pal`) for development:
- `pal test` - Run tests
- `pal build` - Build the project
- `pal run` - Run the project
- `pal next` - Get AI suggestions for next tasks
- `pal commit` - Create well-formatted commits
- `pal switch` - Switch between development machines

## Project-Specific Guidelines
[TODO: Add project-specific guidelines here]
