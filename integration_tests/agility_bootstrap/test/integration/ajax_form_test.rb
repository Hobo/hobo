# -*- coding: utf-8 -*-
require 'test_helper'
require 'integration_test_helper'

class AjaxFormTest < ActionDispatch::IntegrationTest

  self.use_transactional_fixtures = false

  setup do
    DatabaseCleaner.start
    @admin = create(:admin)
    @project = create(:project)
    @s1 = create(:story, :project => @project)
    @s2 = create(:story, :project => @project, :title => "Sample Story 2")
  end

  teardown do
    DatabaseCleaner.clean
  end

  test "ajax forms" do
    Capybara.default_max_wait_time = 10

    visit root_path

    # Resize the window so Bootstrap shows Login button
    Capybara.current_session.driver.resize(1024,700)

    # log in as Administrator
    click_link "Log out" rescue Capybara::ElementNotFound
    click_link "Login"
    fill_in "login", :with => "admin@example.com"
    fill_in "password", :with => "test123"
    click_button "Login"
    assert has_content?("Logged in as Admin User")

    # define statuses
    visit "/story_statuses/index2"

    # verify that qunit tests have passed.
    assert has_content?("0 failed.")

    find("#form1").fill_in("story_status_name", :with => "foo1")
    assert_not page.has_content? 'foo1'
    find("#form1").click_button("new")
    assert find(".statuses table tbody tr:nth-child(1) .story-status-name").has_text?("foo1")

    find("#form2").fill_in("story_status_name", :with => "foo2")
    find("#form2").click_button("new")
    sleep 2
    assert find(".statuses table tbody tr:nth-child(2)").has_text?("foo2")

    find("#form3").fill_in("story_status_name", :with => "foo3")
    find("#form3").click_button("new")
    assert find(".statuses table tbody tr:nth-child(3) .story-status-name").has_text?("foo3")

    find("#form4").fill_in("story_status_name", :with => "foo4")
    find("#form4").click_button("new")
    assert find(".statuses table tbody tr:nth-child(4) .story-status-name").has_text?("foo4")

    find(".statuses table tbody tr:nth-child(1) .delete-button").click
    assert has_no_content?("foo1")
    assert_equal 3, all(".statuses table tbody tr").length

    visit "/story_statuses/index3"
    find(".statuses li:nth-child(1) .delete-button").click
    assert has_no_content?("foo2")
    assert_equal 2, all(".statuses li").length
    assert has_content?("There are 2 Story statuses")

    visit "/story_statuses/index4"
    find(".statuses li:nth-child(1) .delete-button").click
    visit "/story_statuses/index4" # Index4 delete-buttons have Ajax disabled (in-place="&false")
    assert_equal 1, all(".statuses li").length

    find(".statuses li:nth-child(1) .delete-button").click
    visit "/story_statuses/index4" # Index4 delete-buttons have Ajax disabled (in-place="&false")
    assert has_no_content?("foo4")
    assert_equal 0, all(".statuses li").length
    assert has_content?("No records to display")

    visit "/projects/#{@project.id}/show2"
    assert_not_equal "README.md", find(".report-file-name-field .controls").text
    attach_file("project[report]", File.join(::Rails.root, "README.md"))
    click_button "upload new report"
    assert find(".report-file-name-field .controls").has_content?("README.md")

    # these should be set by show2's custom-scripts
    assert find(".events").has_text?("events: rapid:ajax:before rapid:ajax:success rapid:ajax:complete")
    assert find(".callbacks").has_text?("callbacks: before success complete")

    find(".story.odd").fill_in("story_title", :with => "s1")
    page.execute_script("$('.story.odd form').submit()")
    assert find(".story.odd .view.story-title").has_content?("s1")
    assert find(".story.odd .ixz").has_content?("1")

    find(".story.even").fill_in("story_title", :with => "s2")
    page.execute_script("$('.story.even form').submit()")
    assert find(".story.even .view.story-title").has_content?("s2")
    assert find(".story.even .ixz").has_content?("2")

    # update name without errors-ok should display alert
    visit "/projects/#{@project.id}/show2"
    find("#name-form").fill_in("project_name", :with => "invalid name")
    find("#name-form .submit-button").click

    # update name with errors-ok should display error-messages
    visit "/projects/#{@project.id}/show2"
    find("#name-form-ok").fill_in("project_name", :with => "invalid name")
    find("#name-form-ok .submit-button").click
    assert find("#name-form-ok .error-messages").has_content?("1 error")

  end
end
