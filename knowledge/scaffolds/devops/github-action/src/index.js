const core = require('@actions/core');
const github = require('@actions/github');

async function run() {
  try {
    // Read inputs
    const token = core.getInput('token', { required: true });
    const mode = core.getInput('mode') || 'both';
    const configPath = core.getInput('config-path');
    const failOnError = core.getBooleanInput('fail-on-error');

    // Initialize GitHub client
    const octokit = github.getOctokit(token);
    const { owner, repo } = github.context.repo;

    core.info(`Running in mode: ${mode}`);
    core.info(`Repository: ${owner}/${repo}`);

    const results = {
      checks: [],
      warnings: [],
      errors: []
    };

    // Check mode: run validations
    if (mode === 'check' || mode === 'both') {
      core.startGroup('Running checks');

      // Example: check repository metadata
      const { data: repoData } = await octokit.rest.repos.get({ owner, repo });

      if (!repoData.description) {
        results.warnings.push('Repository has no description');
      } else {
        results.checks.push('Repository description is set');
      }

      if (!repoData.license) {
        results.warnings.push('Repository has no license');
      } else {
        results.checks.push(`License: ${repoData.license.spdx_id}`);
      }

      // Check for open issues/PRs count
      if (repoData.open_issues_count > 50) {
        results.warnings.push(`High number of open issues: ${repoData.open_issues_count}`);
      }

      core.endGroup();
    }

    // Report mode: generate summary
    if (mode === 'report' || mode === 'both') {
      core.startGroup('Generating report');

      const { data: pulls } = await octokit.rest.pulls.list({
        owner,
        repo,
        state: 'open',
        per_page: 10
      });

      results.checks.push(`Open PRs: ${pulls.length}`);

      core.endGroup();
    }

    // Determine status
    let status = 'success';
    if (results.errors.length > 0) {
      status = 'failure';
    } else if (results.warnings.length > 0) {
      status = 'warning';
    }

    // Build summary
    const summaryParts = [
      `Checks passed: ${results.checks.length}`,
      `Warnings: ${results.warnings.length}`,
      `Errors: ${results.errors.length}`
    ];
    const summary = summaryParts.join(', ');

    // Set outputs
    core.setOutput('result', JSON.stringify(results));
    core.setOutput('status', status);
    core.setOutput('summary', summary);

    // Log results
    core.info(`Status: ${status}`);
    core.info(`Summary: ${summary}`);

    for (const warning of results.warnings) {
      core.warning(warning);
    }

    for (const error of results.errors) {
      core.error(error);
    }

    // Fail if configured and errors exist
    if (failOnError && results.errors.length > 0) {
      core.setFailed(`Action failed with ${results.errors.length} error(s)`);
    }

  } catch (error) {
    core.setFailed(`Action failed: ${error.message}`);
  }
}

run();
