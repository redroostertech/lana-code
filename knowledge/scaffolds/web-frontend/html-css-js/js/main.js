'use strict'

document.addEventListener('DOMContentLoaded', function () {
  console.log('Site loaded and ready.')

  // Smooth scrolling for anchor links
  document.querySelectorAll('a[href^="#"]').forEach(function (anchor) {
    anchor.addEventListener('click', function (e) {
      var targetId = this.getAttribute('href')
      if (targetId === '#') return

      var target = document.querySelector(targetId)
      if (target) {
        e.preventDefault()
        target.scrollIntoView({ behavior: 'smooth' })
      }
    })
  })
})
